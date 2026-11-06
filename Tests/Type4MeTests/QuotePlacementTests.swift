import AppKit
import XCTest
@testable import Type4Me

/// A quote goes where the user was talking when they began selecting it,
/// whatever the recognizer revised or a mode rewrote afterwards.
final class QuotePlacementTests: XCTestCase {
    // MARK: - By the recognizer's word times

    func testWordTimesGiveTheWordsSaidBeforeTheSelectingBegan() {
        let words = [
            TimedWord(text: "我觉得", end: 1.0),
            TimedWord(text: "这段", end: 1.6),
            TimedWord(text: "写得", end: 2.4),
            TimedWord(text: "不好", end: 2.9),
        ]
        XCTAssertEqual(TimedWord.prefix(words, through: 1.7), "我觉得这段")
        XCTAssertEqual(TimedWord.prefix(words, through: 2.3), "我觉得这段写得", "a word still being said counts as said")
        XCTAssertEqual(TimedWord.prefix(words, through: 0.2), "")
        XCTAssertNil(TimedWord.prefix([], through: 2), "no timing: placed by the words shown instead")
    }

    func testVolcanosWordTimesAreReadFromItsResults() throws {
        let payload: [String: Any] = [
            "result": [
                "text": "看这段代码",
                "utterances": [[
                    "text": "看这段代码", "definite": false, "start_time": 0, "end_time": 2100,
                    "words": [
                        ["text": "看", "start_time": 300, "end_time": 520],
                        ["text": "这段", "start_time": 560, "end_time": 980],
                        ["text": "代码", "start_time": 1500, "end_time": 2100],
                    ],
                ]],
            ],
        ]
        let message = VolcProtocol.encodeMessage(
            header: VolcHeader(messageType: .serverResponse, flags: .noSequence, serialization: .json, compression: .gzip),
            payload: try VolcProtocol.gzipCompress(JSONSerialization.data(withJSONObject: payload))
        )
        let result = try VolcProtocol.decodeServerMessage(message)
        let words = VolcTranscriptAccumulator.timedWords(result.utterances)
        XCTAssertEqual(words.map(\.text), ["看", "这段", "代码"])
        XCTAssertEqual(words.last?.end ?? 0, 2.1, accuracy: 1e-9)

        var accumulator = VolcTranscriptAccumulator()
        let transcript = accumulator.apply(result: result, isFinal: false).transcript
        XCTAssertEqual(transcript.timedWords.count, 3, "carried to the session")
    }

    func testAnUtteranceWithoutWordsStillGivesItsEndTime() {
        let words = VolcTranscriptAccumulator.timedWords([
            VolcUtterance(text: "第一句。", definite: true, end: 1.8),
            VolcUtterance(text: "第二句", definite: false, end: nil),
        ])
        XCTAssertEqual(words, [TimedWord(text: "第一句。", end: 1.8)])
    }

    // MARK: - Without word times

    func testWithoutTimingTheWordsShownJustAfterTheSelectingBeganAreUsed() {
        let heard: [(at: TimeInterval, text: String)] = [
            (10.2, "我觉得"),
            (10.9, "我觉得这段"),   // said before 10.5, shown 0.4 s later
            (11.4, "我觉得这段写得"), // said during the drag
        ]
        let prefix = DictationAttachments.spokenPrefix(
            selectionStart: 10.5, recordingStart: 8, timedWords: [], heard: heard
        )
        XCTAssertEqual(prefix, "我觉得这段", "words that appear later belong after the quote")
    }

    func testWordTimesWinOverTheWordsShown() {
        let prefix = DictationAttachments.spokenPrefix(
            selectionStart: 10.5, recordingStart: 8,
            timedWords: [TimedWord(text: "我觉得", end: 2.0), TimedWord(text: "这段", end: 2.4), TimedWord(text: "写得", end: 3.1)],
            heard: [(10.9, "我觉得这段写得")]
        )
        XCTAssertEqual(prefix, "我觉得这段")
    }

    // MARK: - Delivery

    func testTheFinalWordsTimesPlaceTheQuoteAfterRevisions() {
        // Live, the recognizer had misheard; the final words differ but are timed.
        let quote = PlacedQuote(text: "引用", spokenPrefix: "我觉得折断", audioTime: 1.7)
        let placed = RecognitionSession.placedByTime(quote, words: [
            TimedWord(text: "我觉得", end: 1.0), TimedWord(text: "这段", end: 1.6), TimedWord(text: "写得不好", end: 2.9),
        ])
        XCTAssertEqual(DictationDelivery.text(speech: "我觉得这段写得不好。", quotes: [placed]), "我觉得这段「引用」写得不好。")
    }

    func testWithoutFinalTimingTheLivePlaceIsKept() {
        let quote = PlacedQuote(text: "引用", spokenPrefix: "我觉得这段", audioTime: 1.7)
        XCTAssertEqual(RecognitionSession.placedByTime(quote, words: []), quote)
    }

    // MARK: - Through a rewriting mode

    func testMarkersCarryTheQuotesPlacesThroughARewrite() {
        let quotes = [
            PlacedQuote(text: "甲", spokenPrefix: "第一句"),
            PlacedQuote(text: "乙", spokenPrefix: "第一句第二句"),
        ]
        let marked = QuoteMarkers.mark("第一句第二句第三句", quotes: quotes)
        XCTAssertEqual(marked, "第一句⟦Q1⟧第二句⟦Q2⟧第三句")

        // The model polished the words and kept the markers.
        let extracted = QuoteMarkers.extract("首先，⟦Q1⟧其次，⟦Q2⟧最后。", count: 2)
        XCTAssertEqual(extracted.text, "首先，其次，最后。")
        XCTAssertEqual(extracted.prefixes, ["首先，", "首先，其次，"])
        let placed = zip(quotes, extracted.prefixes!).map { quote, prefix in
            PlacedQuote(text: quote.text, spokenPrefix: prefix)
        }
        XCTAssertEqual(DictationDelivery.text(speech: extracted.text, quotes: placed), "首先，「甲」其次，「乙」最后。")
    }

    func testAMarkerLostOrDoubledGivesNoPlacesButNeverLeaksIntoTheWords() {
        let lost = QuoteMarkers.extract("首先，其次⟦Q2⟧。", count: 2)
        XCTAssertNil(lost.prefixes)
        XCTAssertEqual(lost.text, "首先，其次。")
        let doubled = QuoteMarkers.extract("⟦Q1⟧一⟦Q1⟧二", count: 1)
        XCTAssertNil(doubled.prefixes)
        XCTAssertEqual(doubled.text, "一二")
    }

    func testOnlyOrdinaryDictationModesCarryMarkers() {
        XCTAssertTrue(RecognitionSession.marksQuotes(for: .direct, purpose: .input(.direct)))
        XCTAssertFalse(RecognitionSession.marksQuotes(for: .translation(), purpose: .input(.translation())))
    }
}

/// History keeps what a dictation brought in, small.
final class HistoryMediaTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-media-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in 0..<40 {
            NSColor(hue: CGFloat(i) / 40, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: i * width / 40, y: 0, width: width / 40 + 1, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testAScreenshotIsKeptCompressedAndNoLargerThanTheLimit() throws {
        let media = HistoryMediaStore(root: root)
        let png = try writePNG(width: 3000, height: 1800)
        defer { try? FileManager.default.removeItem(at: png) }

        let shot = try XCTUnwrap(media.saveScreenshot(from: png, id: "rec-1", index: 0))

        XCTAssertEqual(max(shot.width, shot.height), HistoryMediaStore.imageMaxSide)
        let saved = media.url(for: "rec-1", file: shot.file)
        let size = try XCTUnwrap(try saved.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let original = try XCTUnwrap(try png.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, original / 4)
    }

    func testAnUnfinishedRecordingIsKeptSmallAndReadsBack() throws {
        let media = HistoryMediaStore(root: root)
        // Twenty seconds of a 440 Hz tone at 16 kHz mono 16-bit (a file has a
        // fixed overhead, so a dictation-length clip is the fair measure).
        var pcm = Data()
        for n in 0..<320_000 {
            var sample = Int16(sin(Double(n) * 2 * .pi * 440 / 16_000) * 8000)
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let file = try XCTUnwrap(media.saveRecording(pcm: pcm, id: "rec-2"))
        let size = try XCTUnwrap(try media.url(for: "rec-2", file: file).resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, pcm.count / 5, "AAC, not raw PCM")

        let back = try XCTUnwrap(media.loadRecording(id: "rec-2", file: file))
        XCTAssertEqual(Double(back.count), Double(pcm.count), accuracy: Double(pcm.count) * 0.1)
    }

    func testPruningDropsWeekOldRecordingsOrphansAndTheOldestPastTheLimit() throws {
        let media = HistoryMediaStore(root: root)
        let fm = FileManager.default
        func write(_ id: String, _ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            try fm.createDirectory(at: media.folder(for: id), withIntermediateDirectories: true)
            let url = media.url(for: id, file: name)
            try Data(repeating: 1, count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let oldRecording = try write("a", HistoryMediaStore.recordingFile, bytes: 100, age: 8 * 86_400)
        let newRecording = try write("b", HistoryMediaStore.recordingFile, bytes: 100, age: 86_400)
        let oldShot = try write("b", "screenshot-0.heic", bytes: 600, age: 5 * 86_400)
        let newShot = try write("c", "screenshot-0.heic", bytes: 600, age: 60)
        _ = try write("gone", "screenshot-0.heic", bytes: 10, age: 60)

        media.prune(knownIDs: ["a", "b", "c"], byteLimit: 1000)

        XCTAssertFalse(fm.fileExists(atPath: oldRecording.path), "recordings last a week")
        XCTAssertTrue(fm.fileExists(atPath: newRecording.path))
        XCTAssertFalse(fm.fileExists(atPath: oldShot.path), "the oldest makes room")
        XCTAssertTrue(fm.fileExists(atPath: newShot.path))
        XCTAssertFalse(fm.fileExists(atPath: media.folder(for: "gone").path), "no entry, no folder")
    }

    func testTheAttachmentsJSONRoundTripsAndIsAbsentWhenEmpty() {
        XCTAssertNil(HistoryAttachments().json)
        var attachments = HistoryAttachments()
        attachments.quotes = [.init(text: "引用", offset: 5)]
        attachments.screenshots = [.init(file: "screenshot-0.heic", width: 1280, height: 800)]
        attachments.recording = HistoryMediaStore.recordingFile
        XCTAssertEqual(HistoryAttachments.decode(attachments.json), attachments)
    }

    func testHistoryKeepsEachQuoteWhereItWentAndTheScreenshots() throws {
        let media = HistoryMediaStore(root: root)
        let png = try writePNG(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: png) }
        var delivery = DictationDelivery()
        delivery.quotes = [PlacedQuote(text: "春眠不觉晓", spokenPrefix: "我觉得这段")]
        delivery.screenshots = [png]

        let attachments = RecognitionSession.historyAttachments(
            recordID: "rec-3", speech: "我觉得这段写得不好", delivery: delivery, recording: nil, media: media
        )

        XCTAssertEqual(attachments.quotes, [.init(text: "春眠不觉晓", offset: 5)])
        XCTAssertEqual(attachments.screenshots.count, 1)
        XCTAssertTrue(media.exists(id: "rec-3", file: attachments.screenshots[0].file))
        XCTAssertNil(attachments.recording)
    }

    func testDeletingAnEntryDeletesItsMediaAndRecognizingAgainReplacesThePartialWords() async throws {
        let dbPath = root.appendingPathComponent("history.db").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HistoryStore(path: dbPath)
        let pcm = Data(repeating: 0, count: 32_000)
        let file = try XCTUnwrap(store.media.saveRecording(pcm: pcm, id: "rec-4"))
        var attachments = HistoryAttachments()
        attachments.recording = file
        await store.insert(HistoryRecord(
            id: "rec-4", createdAt: Date(), durationSeconds: 2, rawText: "一部分", processingMode: nil,
            processedText: nil, finalText: "一部分", status: "stream_partial", characterCount: 3,
            asrProvider: "test", attachmentsJSON: attachments.json
        ))

        await store.updateRecognizedAgain(id: "rec-4", text: "完整的一句话", attachments: HistoryAttachments())

        let row = await store.fetchAll().first { $0.id == "rec-4" }
        XCTAssertEqual(row?.finalText, "完整的一句话")
        XCTAssertEqual(row?.status, "recognized_again")
        XCTAssertNil(row?.attachments, "nothing left to keep")
        XCTAssertFalse(store.media.exists(id: "rec-4", file: file))

        _ = store.media.saveRecording(pcm: pcm, id: "rec-4")
        await store.delete(id: "rec-4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.media.folder(for: "rec-4").path))
    }

    @MainActor
    func testTheListShowsQuotesInsideTheWordsAndItsCopyInBothLanguages() {
        let text = HistoryQuotedText.attributed("我觉得这段写得不好", quotes: [.init(text: "春眠不觉晓", offset: 5)])
        XCTAssertEqual(String(text.characters), "我觉得这段" + LiveQuoteMark.text("春眠不觉晓") + "写得不好")

        let key = "tf_language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("zh", forKey: key)
        XCTAssertEqual(HistoryAttachmentCopy.quoteCount(2), "2 段引用")
        XCTAssertEqual(HistoryAttachmentCopy.screenshotCount(1), "1 张截图")
        XCTAssertEqual(HistoryAttachmentCopy.recognizeAgain, "重新识别")
        XCTAssertEqual(HistoryAttachmentCopy.cleared, "已清理")
        UserDefaults.standard.set("en", forKey: key)
        XCTAssertEqual(HistoryAttachmentCopy.quoteCount(2), "2 quotes")
        XCTAssertEqual(HistoryAttachmentCopy.screenshotCount(1), "1 screenshot")
        XCTAssertEqual(HistoryAttachmentCopy.recognizeAgain, "Recognize again")
        XCTAssertEqual(HistoryAttachmentCopy.cleared, "Cleared")
    }
}
