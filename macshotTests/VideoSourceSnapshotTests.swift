import AVFoundation
import XCTest

@MainActor
final class VideoSourceSnapshotTests: XCTestCase {
    private var directory: URL!
    private let cleanup = DispatchQueue(label: "macshot.tests.source-cleanup")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cleanup.sync {}
        try FileManager.default.removeItem(at: directory)
    }

    func testCloneAndFallbackRemainUnchangedAfterInPlaceAndAtomicSourceReplacement() throws {
        for clone in [true, false] {
            let source = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            let bytes = Data(repeating: 0x61, count: 3 * 1024 * 1024 + 17)
            try bytes.write(to: source)
            let snapshot = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
                workspaceRoot: directory.appendingPathComponent("working"), allowClone: clone, cleanupQueue: cleanup)
            let handle = try FileHandle(forWritingTo: source)
            try handle.write(contentsOf: Data("changed in place".utf8))
            try handle.close()
            XCTAssertEqual(try Data(contentsOf: snapshot.mediaURL), bytes)
            let replacement = try AtomicMediaSave(destinationURL: source)
            try Data("exported replacement".utf8).write(to: replacement.stagingURL)
            try replacement.commit()
            snapshot.didSave(at: source)
            XCTAssertEqual(try Data(contentsOf: snapshot.mediaURL), bytes)
            XCTAssertEqual(try Data(contentsOf: source), Data("exported replacement".utf8))
        }
    }

    func testReadLeaseOutlivesEditorAndPreservesThePublishedTemporaryInput() throws {
        let source = directory.appendingPathComponent("disposable.mp4")
        try Data("old source".utf8).write(to: source)
        var snapshot: VideoSourceSnapshot? = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: true,
            workspaceRoot: directory.appendingPathComponent("working"), cleanupQueue: cleanup)
        let readURL = try XCTUnwrap(snapshot?.mediaURL)
        var readerLease = snapshot?.lease
        snapshot = nil
        cleanup.sync {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: readURL.path))
        let save = try AtomicMediaSave(destinationURL: source)
        try Data("published file".utf8).write(to: save.stagingURL)
        try save.commit()
        readerLease?.preserve(ifSavedAt: source)
        readerLease = nil
        cleanup.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: readURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), Data("published file".utf8))
    }

    func testFailedOrCancelledPreparationRetainsInputAndRemovesWorkingDirectory() throws {
        let source = directory.appendingPathComponent("input.mp4")
        let original = Data(repeating: 0x62, count: 3 * 1024 * 1024)
        try original.write(to: source)
        let root = directory.appendingPathComponent("working")
        let cancellation = MediaExportCancellation()
        XCTAssertThrowsError(try VideoSourceSnapshot.prepare(url: source, deleteOnClose: true,
            workspaceRoot: root, allowClone: false, cleanupQueue: cleanup, cancellation: cancellation,
            progress: { _ in cancellation.cancel() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertThrowsError(try VideoSourceSnapshot.prepare(url: source, deleteOnClose: true,
            workspaceRoot: source, cleanupQueue: cleanup))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testOverwritingDurableTakeRetainsItsOriginalBytesAfterEditorClose() throws {
        let recordingRoot = directory.appendingPathComponent("Recordings")
        let take = try RecordingSessionStore(filename: "Take", root: recordingRoot)
        let bytes = Data("durable original".utf8)
        try bytes.write(to: take.mediaURL)
        var snapshot: VideoSourceSnapshot? = try VideoSourceSnapshot.prepare(url: take.mediaURL, deleteOnClose: true,
            recordingRoot: recordingRoot, cleanupQueue: cleanup)
        let backup = try XCTUnwrap(snapshot?.mediaURL)
        XCTAssertTrue(backup.path.hasPrefix(take.directoryURL.resolvingSymlinksInPath().path + "/"))
        let save = try AtomicMediaSave(destinationURL: take.mediaURL)
        try Data("edited replacement".utf8).write(to: save.stagingURL)
        try save.commit()
        snapshot?.didSave(at: take.mediaURL)
        snapshot = nil
        cleanup.sync {}
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try Data(contentsOf: take.mediaURL), Data("edited replacement".utf8))
    }

    func testOpeningThroughALinkStillKeepsRecordingBackupInTheDurableSession() throws {
        let recordingRoot = directory.appendingPathComponent("Recordings")
        let take = try RecordingSessionStore(filename: "Take", root: recordingRoot)
        let original = Data("original recording".utf8)
        try original.write(to: take.mediaURL)
        let link = directory.appendingPathComponent("linked-take.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: take.mediaURL)
        var snapshot: VideoSourceSnapshot? = try VideoSourceSnapshot.prepare(url: link, deleteOnClose: false,
            recordingRoot: recordingRoot, cleanupQueue: cleanup)
        let backup = try XCTUnwrap(snapshot?.mediaURL)
        XCTAssertTrue(RecordingSessionStore.owns(link, root: recordingRoot))
        XCTAssertTrue(backup.path.hasPrefix(take.directoryURL.resolvingSymlinksInPath().path + "/"))
        let save = try AtomicMediaSave(destinationURL: take.mediaURL)
        try Data("replacement".utf8).write(to: save.stagingURL)
        try save.commit()
        snapshot?.didSave(at: take.mediaURL)
        snapshot = nil
        cleanup.sync {}
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testTwoOpenSourcesCanExportLaterEditsAfterReplacingTheirPublicInput() async throws {
        let publicURL = try await RecordingMediaFixture.mixedMovie(in: directory)
        let first = try VideoSourceSnapshot.prepare(url: publicURL, deleteOnClose: false,
            workspaceRoot: directory.appendingPathComponent("one"), cleanupQueue: cleanup)
        let second = try VideoSourceSnapshot.prepare(url: publicURL, deleteOnClose: false,
            workspaceRoot: directory.appendingPathComponent("two"), cleanupQueue: cleanup)
        let original = try Data(contentsOf: first.mediaURL)
        for (source, start, duration) in [(first, 0.0, 0.5), (second, 1.0, 0.8), (first, 0.5, 1.0)] {
            let prepared = try await PreparedVideoSource.load(source)
            let asset = try XCTUnwrap(prepared.asset)
            XCTAssertEqual(prepared.pixelSize, CGSize(width: 64, height: 64))
            XCTAssertEqual(prepared.duration, 2, accuracy: 1.0 / 30)
            XCTAssertEqual(asset.duration.seconds, 2, accuracy: 1.0 / 30)
            let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
            session.outputFileType = .mp4
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 30),
                duration: CMTime(seconds: duration, preferredTimescale: 30))
            let job = VideoExportJob(session: session, sourceLease: source.lease)
            let save = try AtomicMediaSave(destinationURL: publicURL)
            try await job.export(to: save.stagingURL)
            try save.commit()
            source.didSave(at: publicURL)
            let output = AVAsset(url: publicURL)
            XCTAssertEqual(output.duration.seconds, duration, accuracy: 1.0 / 30)
            XCTAssertEqual(output.tracks(withMediaType: .audio).count, 2)
            let reader = try AVAssetReader(asset: output)
            let video = AVAssetReaderTrackOutput(track: try XCTUnwrap(output.tracks(withMediaType: .video).first),
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(video)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let sample = video.copyNextSampleBuffer() { XCTAssertNotNil(sample.imageBuffer); count += 1 }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(count, Int((duration * 30).rounded()))
        }
        XCTAssertEqual(try Data(contentsOf: first.mediaURL), original)
        XCTAssertEqual(try Data(contentsOf: second.mediaURL), original)
    }

    func testAssetKeepsWorkingFileAfterEditorAndPreparedSourceAreReleased() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        var snapshot: VideoSourceSnapshot? = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
            workspaceRoot: directory.appendingPathComponent("working"), cleanupQueue: cleanup)
        var prepared: PreparedVideoSource? = try await PreparedVideoSource.load(XCTUnwrap(snapshot))
        let workingURL = try XCTUnwrap(snapshot?.mediaURL)
        var reader: AVAsset? = prepared?.asset
        prepared = nil
        snapshot = nil
        cleanup.sync {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        XCTAssertEqual(try XCTUnwrap(reader).duration.seconds, 2, accuracy: 1.0 / 30)
        reader = nil
        cleanup.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAbandonedCopySweepSkipsActiveReadersAndFreshDirectories() throws {
        let source = directory.appendingPathComponent("input.mp4")
        try Data("input".utf8).write(to: source)
        let root = directory.appendingPathComponent("working")
        let snapshot = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
            workspaceRoot: root, cleanupQueue: cleanup)
        let active = snapshot.mediaURL.deletingLastPathComponent()
        let orphan = root.appendingPathComponent(UUID().uuidString)
        let fresh = root.appendingPathComponent(UUID().uuidString)
        for folder in [orphan, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("abandoned copy".utf8).write(to: folder.appendingPathComponent("input.mp4"))
        }
        let now = Date()
        for folder in [active, orphan] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-48 * 60 * 60)], ofItemAtPath: folder.path)
        }
        XCTAssertEqual(VideoSourceSnapshot.removeAbandonedTemporaryCopies(root: root, now: now), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.mediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        withExtendedLifetime(snapshot) {}
    }

    func testCancellingMetadataLoadDoesNotWaitForTheMediaProvider() async throws {
        let entered = expectation(description: "Asset reader requested bytes")
        let finished = expectation(description: "Metadata task finished")
        let loader = StalledVideoResourceLoader(entered: entered)
        let asset = AVURLAsset(url: URL(string: "macshot-fixture:///stalled.mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "macshot.tests.stalled-reader"))
        var result: Result<PreparedVideoSource.Metadata, Error>?
        let task = Task {
            do { result = .success(try await PreparedVideoSource.loadMetadata(for: asset)) }
            catch { result = .failure(error) }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await fulfillment(of: [finished], timeout: 5)
        // On a regression, finish the synthetic request so a failed assertion
        // cannot leave an unbounded background task in the test runner.
        loader.finishPending()
        guard case .failure(let error) = result else { return XCTFail("Metadata load did not finish with cancellation") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        withExtendedLifetime(loader) {}
    }
}

private final class StalledVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let entered: XCTestExpectation
    private let lock = NSLock()
    nonisolated(unsafe) private var requests: [AVAssetResourceLoadingRequest] = []
    nonisolated init(entered: XCTestExpectation) {
        self.entered = entered
    }
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                   shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock(); requests.append(request); lock.unlock()
        entered.fulfill()
        return true
    }
    nonisolated func finishPending() {
        lock.lock(); let pending = requests; requests.removeAll(); lock.unlock()
        for request in pending where !request.isFinished && !request.isCancelled {
            request.finishLoading(with: URLError(.cancelled))
        }
    }
}
