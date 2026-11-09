#if !OFFLINE
import CryptoKit
import XCTest

/// Uploads used to read the whole file into memory and then build a request
/// body from it — two extra copies of a recording that is routinely larger than
/// a gigabyte. These cover the streaming replacement: same bytes out, flat
/// memory in.
final class UploadPayloadTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-payload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(bytes: Int, seed: UInt8 = 7) throws -> (URL, Data) {
        let data = Data((0..<bytes).map { UInt8(($0 &* 31 &+ Int(seed)) % 251) })
        let url = directory.appendingPathComponent("payload-\(bytes).bin")
        try data.write(to: url)
        return (url, data)
    }

    private func collect(_ payload: UploadPayload) throws -> Data {
        var collected = Data()
        try payload.forEachChunk { collected.append($0) }
        return collected
    }

    // MARK: - Chunking

    func testAFilePayloadStreamsExactlyItsBytes() throws {
        let (url, expected) = try makeFile(bytes: 3 * UploadPayload.chunkSize + 1234)
        XCTAssertEqual(try collect(.file(url)), expected, "streaming must not drop or duplicate a byte")
    }

    func testADataPayloadStreamsExactlyItsBytes() throws {
        let (_, expected) = try makeFile(bytes: UploadPayload.chunkSize * 2 + 5)
        XCTAssertEqual(try collect(.data(expected)), expected)
    }

    func testAnEmptyPayloadProducesNothing() throws {
        let url = directory.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        XCTAssertTrue(try collect(.file(url)).isEmpty)
        XCTAssertTrue(try collect(.data(Data())).isEmpty)
    }

    func testChunksNeverExceedTheChunkSize() throws {
        let (url, _) = try makeFile(bytes: UploadPayload.chunkSize * 2 + 17)
        var sizes: [Int] = []
        try UploadPayload.file(url).forEachChunk { sizes.append($0.count) }
        XCTAssertFalse(sizes.isEmpty)
        for size in sizes {
            XCTAssertLessThanOrEqual(size, UploadPayload.chunkSize,
                                     "a chunk bigger than the limit defeats the point of streaming")
        }
    }

    func testAMissingFileThrowsInsteadOfUploadingNothing() {
        let missing = directory.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try collect(.file(missing)))
    }

    func testByteCountMatchesTheContent() throws {
        let (url, data) = try makeFile(bytes: 4096)
        XCTAssertEqual(UploadPayload.file(url).byteCount, 4096)
        XCTAssertEqual(UploadPayload.data(data).byteCount, 4096)
    }

    // MARK: - Hashing

    func testStreamedHashMatchesHashingItAllAtOnce() throws {
        // AWS rejects the request outright if the content hash is wrong, so the
        // incremental hash has to agree with the whole-file one exactly.
        for size in [0, 1, 1024, UploadPayload.chunkSize, UploadPayload.chunkSize * 2 + 99] {
            let (url, data) = try makeFile(bytes: size)
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try UploadPayload.file(url).sha256Hex(), expected, "size \(size)")
            XCTAssertEqual(try UploadPayload.data(data).sha256Hex(), expected, "size \(size)")
        }
    }

    func testHashOfAKnownValue() throws {
        // Sanity-check the hex formatting against a published vector.
        XCTAssertEqual(try UploadPayload.data(Data("abc".utf8)).sha256Hex(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Writing bodies

    func testWritingAPayloadReproducesTheFileExactly() throws {
        let (source, data) = try makeFile(bytes: UploadPayload.chunkSize + 77)
        let destination = directory.appendingPathComponent("copy.bin")
        try UploadPayload.file(source).write(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testTheMultipartBodyMatchesTheInMemoryFormat() throws {
        // The bytes on the wire must be identical to what the old in-memory
        // construction produced, or Drive rejects the upload.
        let (fileURL, fileData) = try makeFile(bytes: UploadPayload.chunkSize + 512)
        let metadata = Data(#"{"name":"clip.mp4","parents":["folder-id"]}"#.utf8)
        let boundary = "test-boundary"
        let destination = directory.appendingPathComponent("body.tmp")

        try MultipartBodyWriter.writeRelatedBody(
            metadata: metadata, mimeType: "video/mp4", boundary: boundary,
            payload: .file(fileURL), to: destination)

        var expected = Data()
        expected.append(Data("--\(boundary)\r\n".utf8))
        expected.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        expected.append(metadata)
        expected.append(Data("\r\n--\(boundary)\r\n".utf8))
        expected.append(Data("Content-Type: video/mp4\r\n\r\n".utf8))
        expected.append(fileData)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))

        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testAFailedBodyWriteLeavesNoPartialFile() throws {
        let destination = directory.appendingPathComponent("aborted.tmp")
        struct Boom: Error {}

        XCTAssertThrowsError(try MultipartBodyWriter.write(to: destination) { append in
            try append(Data("some bytes".utf8))
            throw Boom()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a half-written body must not be left behind for the next upload to send")
    }

    func testWritingOverAnExistingFileReplacesIt() throws {
        let destination = directory.appendingPathComponent("existing.tmp")
        try Data("old and much longer content".utf8).write(to: destination)

        try UploadPayload.data(Data("new".utf8)).write(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testALargePayloadIsWrittenInBoundedPieces() throws {
        // Resident memory is a poor probe (freed chunks stay in the malloc
        // zone), so assert the property that actually matters: no single
        // append carries the whole payload.
        // 16 MiB is plenty to prove chunking without making the rest of the
        // suite fight this test for memory.
        let size = 16 * 1024 * 1024
        let url = directory.appendingPathComponent("big.bin")
        let chunk = Data(repeating: 0xAB, count: UploadPayload.chunkSize)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<(size / UploadPayload.chunkSize) { try handle.write(contentsOf: chunk) }
        try handle.close()

        var largestAppend = 0
        var totalAppended = 0
        let destination = directory.appendingPathComponent("big-body.tmp")
        try MultipartBodyWriter.write(to: destination) { append in
            try UploadPayload.file(url).forEachChunk { piece in
                largestAppend = max(largestAppend, piece.count)
                totalAppended += piece.count
                try append(piece)
            }
        }

        XCTAssertEqual(totalAppended, size, "every byte must reach the body")
        XCTAssertLessThanOrEqual(largestAppend, UploadPayload.chunkSize,
                                 "a \(size / 1_048_576)MB payload was appended in one piece")
        XCTAssertGreaterThan(size / UploadPayload.chunkSize, 1, "the fixture must span several chunks")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int, size)
    }

    func testAMultipartBodyForALargeFileHasTheRightLength() throws {
        let size = 8 * 1024 * 1024
        let (url, _) = try makeFile(bytes: size)
        let destination = directory.appendingPathComponent("sized-body.tmp")
        let boundary = "b"
        try MultipartBodyWriter.writeRelatedBody(
            metadata: Data("{}".utf8), mimeType: "video/mp4", boundary: boundary,
            payload: .file(url), to: destination)

        let headerBytes = "--\(boundary)\r\n".utf8.count
            + "Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8.count
            + "{}".utf8.count
            + "\r\n--\(boundary)\r\n".utf8.count
            + "Content-Type: video/mp4\r\n\r\n".utf8.count
            + "\r\n--\(boundary)--\r\n".utf8.count
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
                       size + headerBytes, "body should be the payload plus its headers")
    }
}
#endif
