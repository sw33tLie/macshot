#if !OFFLINE
import Foundation
import XCTest

final class CustomUploaderTests: XCTestCase {

    private func config(_ json: String) throws -> CustomUploaderConfig {
        try CustomUploaderConfig(sxcu: Data(json.utf8))
    }

    private func response(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> CustomUploaderResponse {
        CustomUploaderResponse(statusCode: status, body: Data(body.utf8), headers: headers,
                               responseURL: "https://img.example.com/api/upload", filename: "shot.png")
    }

    private let zipline = """
        {"Version":"14.1.0","Name":"Zipline","DestinationType":"ImageUploader, FileUploader",
         "RequestMethod":"POST","RequestURL":"https://img.example.com/api/upload",
         "Headers":{"Authorization":"tok"},"Body":"MultipartFormData","FileFormName":"file",
         "URL":"{json:files[0].url}"}
        """

    func testCurrentFormatIsParsed() throws {
        let cfg = try config(zipline)
        XCTAssertEqual(cfg.name, "Zipline")
        XCTAssertEqual(cfg.method, "POST")
        XCTAssertEqual(cfg.body, .multipart)
        XCTAssertEqual(cfg.fileFormName, "file")
        XCTAssertEqual(cfg.host, "img.example.com")
        let request = try cfg.request(filename: "shot.png")
        XCTAssertEqual(request.url?.absoluteString, "https://img.example.com/api/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "tok")
    }

    func testLegacyFormatIsParsed() throws {
        let cfg = try config("""
            {"Name":"XBackBone","RequestType":"POST","RequestURL":"https://x.example.com/upload",
             "FileFormName":"upload","Arguments":{"token":"abc"},
             "URL":"$json:url$","DeletionURL":"$json:url$/delete/$json:id$"}
            """)
        XCTAssertEqual(cfg.body, .multipart)
        XCTAssertEqual(cfg.formFields(filename: "shot.png").map(\.value), ["abc"])
        let result = try cfg.result(from: response(#"{"url":"https://x.example.com/a","id":7}"#))
        XCTAssertEqual(result.link, "https://x.example.com/a")
        XCTAssertEqual(result.deleteURL, "https://x.example.com/a/delete/7")
    }

    func testBinaryBodyAndMissingNameFallBackToHost() throws {
        let cfg = try config(#"{"RequestMethod":"PUT","RequestURL":"https://files.example.com/put","Body":"Binary"}"#)
        XCTAssertEqual(cfg.body, .binary)
        XCTAssertEqual(cfg.method, "PUT")
        XCTAssertEqual(cfg.name, "files.example.com")
    }

    func testFilenameAndParametersReachTheRequestURL() throws {
        let cfg = try config("""
            {"RequestURL":"https://e.example.com/u/{filename}","Body":"Binary",
             "Parameters":{"name":"{filename}"},"Headers":{"Content-Length":"1","X-Key":"k"}}
            """)
        let request = try cfg.request(filename: "shot.png")
        XCTAssertEqual(request.url?.absoluteString, "https://e.example.com/u/shot.png?name=shot.png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Key"), "k")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Length"))
    }

    func testUnsupportedUploadersAreRejected() {
        let cases: [(String, CustomUploaderError)] = [
            ("not json", .unreadableFile),
            (#"{"Name":"x"}"#, .unreadableFile),
            (#"{"DestinationType":"URLShortener","RequestURL":"https://e.example.com","Body":"Binary"}"#, .notFileUploader),
            (#"{"RequestURL":"https://e.example.com","Body":"JSON"}"#, .unsupportedBody("JSON")),
            (#"{"RequestURL":"https://e.example.com","Body":"None"}"#, .unsupportedBody("None")),
            (#"{"RequestMethod":"GET","RequestURL":"https://e.example.com","Body":"Binary"}"#, .unsupportedMethod("GET")),
            (#"{"RequestURL":"ftp://e.example.com","Body":"Binary"}"#, .invalidRequestURL),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try config(json), json) {
                XCTAssertEqual($0 as? CustomUploaderError, expected, json)
            }
        }
    }

    func testJSONPathsResolve() {
        let reply = response(#"{"files":[{"url":"https://e.example.com/1"}],"data":{"link":"https://e.example.com/2","size":12}}"#)
        XCTAssertEqual(reply.resolve("{json:files[0].url}"), "https://e.example.com/1")
        XCTAssertEqual(reply.resolve("{json:$.data.link}"), "https://e.example.com/2")
        XCTAssertEqual(reply.resolve("$json:data.link$?s=$json:data.size$"), "https://e.example.com/2?s=12")
        XCTAssertEqual(reply.resolve("{json:files[3].url}"), "")
        XCTAssertEqual(reply.resolve("{unknown:x} stays"), "{unknown:x} stays")
    }

    func testRegexHeaderAndResponsePlaceholdersResolve() {
        let reply = response(#"<a href="https://e.example.com/x.png">ok</a>"#, headers: ["location": "https://e.example.com/y"])
        XCTAssertEqual(reply.resolve(#"{regex:href="([^"]+)"|1}"#), "https://e.example.com/x.png")
        XCTAssertEqual(reply.resolve("$regex:1,1$", regexList: [#"href="([^"]+)""#]), "https://e.example.com/x.png")
        XCTAssertEqual(reply.resolve(#"{regex:a\|ok}"#), "a")
        XCTAssertEqual(reply.resolve("{header:Location}"), "https://e.example.com/y")
        XCTAssertEqual(reply.resolve("{responseurl}/{filename}"), "https://img.example.com/api/upload/shot.png")
    }

    func testAnEmptyURLTemplateUsesTheResponseBody() throws {
        let cfg = try config(#"{"RequestURL":"https://e.example.com","Body":"Binary"}"#)
        XCTAssertEqual(try cfg.result(from: response("https://e.example.com/z\n")).link, "https://e.example.com/z")
    }

    func testOnlyWebLinksAreAccepted() throws {
        let cfg = try config(zipline)
        for body in [#"{"files":[{"url":"javascript:alert(1)"}]}"#, #"{"files":[]}"#, "oops"] {
            XCTAssertThrowsError(try cfg.result(from: response(body)), body) {
                XCTAssertEqual($0 as? CustomUploaderError, .noLinkInResponse)
            }
        }
    }

    func testServerErrorsUseTheConfiguredMessage() throws {
        let cfg = try config("""
            {"RequestURL":"https://e.example.com","Body":"Binary","ErrorMessage":"{json:error}"}
            """)
        XCTAssertThrowsError(try cfg.result(from: response(#"{"error":"bad token"}"#, status: 401))) {
            XCTAssertEqual($0 as? CustomUploaderError, .server(401, "bad token"))
        }
        XCTAssertThrowsError(try cfg.result(from: response("", status: 500))) {
            XCTAssertEqual($0 as? CustomUploaderError, .server(500, "HTTP 500"))
        }
    }

    func testMultipartBodyCarriesFieldsBeforeTheFile() throws {
        let body = try PreparedUploadBody(formFile: .data(Data("PNG".utf8)), fieldName: "file", filename: "a\"b.png",
                                          contentType: "image/png", fields: [(name: "token", value: "abc")], boundary: "B")
        let expected = "--B\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nabc\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a%22b.png\"\r\nContent-Type: image/png\r\n\r\n"
            + "PNG\r\n--B--\r\n"
        XCTAssertEqual(String(decoding: try Data(contentsOf: body.url), as: UTF8.self), expected)
        XCTAssertEqual(body.byteCount, expected.utf8.count)
    }
}
#endif
