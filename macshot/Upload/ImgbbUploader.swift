#if !OFFLINE
import Cocoa

struct ImageUploadResult {
    let link: String
    let deleteURL: String
}

enum ImageUploader {

    private static let defaultAPIKey = "c2c63d156c6baa11136a464dcd22a404"

    static var apiKey: String {
        if let custom = UserDefaults.standard.string(forKey: "imgbbAPIKey"), !custom.isEmpty {
            return custom
        }
        return defaultAPIKey
    }

    static func upload(image: NSImage, session: URLSession = .shared, key: String? = nil,
                       completion: @escaping (Result<ImageUploadResult, Error>) -> Void) {
        let snapshot: HistoryImageSnapshot.Image
        do { snapshot = try HistoryImageSnapshot.Image(image) }
        catch { completion(.failure(error)); return }
        let selectedKey = (key ?? apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        UploadJob.start(filename: "Screenshot.png", operation: {
            let boundary = UUID().uuidString
            let body = try await MediaExportIO.perform {
                let png = try PreparedUploadBody(payload: .image(snapshot))
                return try PreparedUploadBody(formImage: png, boundary: boundary)
            }
            var components = URLComponents(string: "https://api.imgbb.com/1/upload")!
            components.queryItems = [URLQueryItem(name: "key", value: selectedKey)]
            guard let url = components.url else { throw uploadError("Invalid imgbb API key") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: nil)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200...299).contains(response.statusCode), json?["success"] as? Bool == true,
                  let result = json?["data"] as? [String: Any],
                  let link = result["url"] as? String, let deleteURL = result["delete_url"] as? String else {
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                    ?? "imgbb returned HTTP \(response.statusCode) or an unreadable response"
                throw uploadError(message)
            }
            return ImageUploadResult(link: link, deleteURL: deleteURL)
        }, completion: completion)
    }

    private static func uploadError(_ message: String) -> NSError {
        NSError(domain: "ImageUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
