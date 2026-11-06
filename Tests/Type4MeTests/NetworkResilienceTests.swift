import XCTest
import os
@testable import Type4Me

/// A bad network must never lose the words, paste them somewhere else, or
/// leave the bar stuck (the 2026-11-06 22:19 trace: a stalled upload, Volcano's
/// 45000081, and two paths racing to end the session).
final class NetworkResilienceTests: XCTestCase {
    // MARK: - Reading the server's errors

    func testVolcanosAudioTimeoutAndServiceErrorsAreADroppedStreamNotAnAccountVerdict() {
        let timeout = VolcProtocolError.serverError(
            code: 45_000_081,
            message: "Timed out waiting for the next audio packet. The session has ended."
        )
        XCTAssertFalse(timeout.isTerminalServerError)
        XCTAssertFalse(VolcProtocolError.serverError(code: 55_000_031, message: "server busy").isTerminalServerError)
        XCTAssertFalse(VolcProtocolError.serverError(code: 55_000_000, message: "internal").isTerminalServerError)
    }

    func testAccountAndRequestErrorsStillEndTheSessionWithTheServersWords() {
        XCTAssertTrue(VolcProtocolError.serverError(code: 45_000_030, message: "quota exceeded").isTerminalServerError)
        XCTAssertTrue(VolcProtocolError.serverError(code: 45_000_001, message: "invalid request").isTerminalServerError)
        XCTAssertTrue(VolcProtocolError.serverError(code: nil, message: "denied").isTerminalServerError)
    }

    // MARK: - Waiting budgets

    func testAfterReleaseItWaitsOnOnlyWhileWordsAreStillArriving() {
        let release = ContinuousClock.now
        let quiet: Duration = .milliseconds(2500)
        let cap: Duration = .seconds(8)
        // Words 4.3 s after release: wait until 6.8 s.
        XCTAssertEqual(
            RecognitionSession.nextFinalDeadline(started: release, lastWords: release + .milliseconds(4300),
                                                 quietWait: quiet, cap: cap, now: release + .seconds(5)),
            release + .milliseconds(6800)
        )
        // Nothing since before release: a silent server is not waited on.
        XCTAssertNil(RecognitionSession.nextFinalDeadline(started: release, lastWords: release - .seconds(1),
                                                          quietWait: quiet, cap: cap, now: release + .seconds(3)))
        // Still trickling at 7.5 s: never past the cap.
        XCTAssertEqual(
            RecognitionSession.nextFinalDeadline(started: release, lastWords: release + .milliseconds(7500),
                                                 quietWait: quiet, cap: cap, now: release + .milliseconds(7600)),
            release + cap
        )
    }

    func testRecognizingTheWholeRecordingAgainHasABoundedBudget() {
        XCTAssertEqual(RecognitionSession.batchFallbackBudget(audioBytes: 0), .seconds(12))
        // A minute of 16 kHz 16-bit audio.
        XCTAssertEqual(RecognitionSession.batchFallbackBudget(audioBytes: 1_920_000), .seconds(24))
        XCTAssertEqual(RecognitionSession.batchFallbackBudget(audioBytes: 32_000 * 600), .seconds(30))
    }

    // MARK: - A stream that drops while the user talks

    func testADroppedStreamKeepsRecordingAndTheWholeRecordingIsRecognizedOnRelease() async throws {
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let session = try await makeSession(retries: retries, retryResult: "前半句和断网后说的后半句")
        await session.setOnASREvent { event in events.withLock { $0.append(Self.name(of: event)) } }
        await session.ingestASREventForTesting(.transcript(.partial("前半句")))

        await session.ingestASREventForTesting(.error(URLError(.networkConnectionLost)))

        let state = await session.state
        let lost = await session.streamLost
        XCTAssertEqual(state, .recording, "the microphone stays on; the user is still talking")
        XCTAssertTrue(lost)
        XCTAssertEqual(events.withLock { $0 }.filter { $0 != "transcript" }, ["connectionLost"], "no red error, and nothing pasted yet")

        await session.stopRecording()

        XCTAssertEqual(retries.withLock { $0 }, 1)
        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "前半句和断网后说的后半句", "goes out through the normal delivery, to the locked box")
        let keeps = await session.keepsUnfinishedRecordingForTesting()
        XCTAssertFalse(keeps)
        XCTAssertTrue(events.withLock { $0 }.contains("retryingFullRecording"))
    }

    func testWhenTheRetryFailsTooTheHeardWordsStillGoOutAndTheRecordingIsKept() async throws {
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(retries: retries, retryResult: nil)
        await session.ingestASREventForTesting(.transcript(.partial("网络断之前的话")))
        await session.ingestASREventForTesting(.error(URLError(.timedOut)))

        await session.stopRecording()

        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "网络断之前的话")
        let keeps = await session.keepsUnfinishedRecordingForTesting()
        XCTAssertTrue(keeps, "kept to be recognized again from history")
    }

    func testAStreamThatDropsBeforeAnyWordsIsStillRecognizedNotThrownAway() async throws {
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(retries: retries, retryResult: "全部是断网后说的", speechDetected: false)
        await session.ingestASREventForTesting(.error(URLError(.networkConnectionLost)))

        await session.stopRecording()

        XCTAssertEqual(retries.withLock { $0 }, 1)
        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "全部是断网后说的")
    }

    func testVolcanosTimeoutThenItsCloseIsOneDroppedStreamNotARace() async throws {
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let session = try await makeSession(retries: retries, retryResult: "完整")
        await session.setOnASREvent { event in events.withLock { $0.append(Self.name(of: event)) } }
        await session.ingestASREventForTesting(.transcript(.partial("一部分")))

        await session.ingestASREventForTesting(.error(VolcProtocolError.serverError(code: 45_000_081, message: "timed out")))
        await session.ingestASREventForTesting(.completed)

        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(events.withLock { $0 }.filter { $0 == "connectionLost" }.count, 1)
        XCTAssertFalse(events.withLock { $0 }.contains("error"))
    }

    func testAnAccountVerdictEndsTheSessionOnceAndNothingElseClaimsIt() async throws {
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let done = expectation(description: "session ended")
        done.assertForOverFulfill = false
        let session = try await makeSession(retries: retries, retryResult: "x")
        await session.setOnASREvent { event in
            events.withLock { $0.append(Self.name(of: event)) }
            if case .completed = event { done.fulfill() }
        }

        await session.ingestASREventForTesting(.error(VolcProtocolError.serverError(code: 45_000_030, message: "quota exceeded")))
        // The server's close arrives before the teardown has run.
        await session.ingestASREventForTesting(.completed)
        let claimed = await session.endsWithTerminalErrorForTesting()
        XCTAssertTrue(claimed)
        await session.stopRecording()

        await fulfillment(of: [done], timeout: 2)
        let state = await session.state
        XCTAssertEqual(state, .idle, "never stuck")
        XCTAssertEqual(retries.withLock { $0 }, 0)
        let seen = events.withLock { $0 }
        XCTAssertEqual(seen.filter { $0 == "error" }.count, 1)
        XCTAssertEqual(seen.filter { $0 == "completed" }.count, 1, "the session ends once")
        XCTAssertFalse(seen.contains("connectionLost"))
    }

    func testOnlyAFailingNetworkKeepsTheRecordingOtherFailuresStillShowAtOnce() {
        XCTAssertTrue(RecognitionSession.isNetworkFailure(URLError(.timedOut)))
        XCTAssertTrue(RecognitionSession.isNetworkFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(RecognitionSession.isNetworkFailure(URLError(.cannotConnectToHost)))
        XCTAssertFalse(RecognitionSession.isNetworkFailure(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(RecognitionSession.isNetworkFailure(URLError(.badServerResponse)))
        XCTAssertFalse(RecognitionSession.isNetworkFailure(VolcProtocolError.serverError(code: 45_000_030, message: "quota")))
    }

    func testWhenNothingAtAllCouldBeRecognizedTheRecordingIsKeptAndTheUserIsTold() async throws {
        let key = "tf_language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("zh", forKey: key)
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let messages = OSAllocatedUnfairLock(initialState: [String]())
        let session = try await makeSession(retries: retries, retryResult: nil, speechDetected: false)
        await session.setOnASREvent { event in
            if case .error(let error) = event { messages.withLock { $0.append(error.localizedDescription) } }
        }
        await session.ingestASREventForTesting(.error(URLError(.notConnectedToInternet)))

        await session.stopRecording()

        XCTAssertEqual(retries.withLock { $0 }, 1)
        XCTAssertEqual(messages.withLock { $0 }, ["网络不好，没能识别，录音已存到历史，可重新识别"])
        let keeps = await session.keepsUnfinishedRecordingForTesting()
        XCTAssertFalse(keeps, "handed to history")
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - After release on a slow network

    func testWordsThatKeepArrivingAfterReleaseAreWaitedForPastTheFirstWait() async throws {
        // Revisions keep coming after the first 3 s wait (the 22:37 trace); the
        // last one must not be cut off. No final event is ever sent.
        let client = TrickleASRStub(revisions: [
            (.milliseconds(400), "慢慢"),
            (.milliseconds(2600), "慢慢到达"),
            (.milliseconds(4300), "慢慢到达的最后几个字"),
        ])
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(retries: retries, retryResult: nil, client: client, provider: .volcano)
        await session.ingestASREventForTesting(.transcript(.partial("慢")))
        let started = ContinuousClock.now

        await session.stopRecording()

        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "慢慢到达的最后几个字")
        XCTAssertEqual(retries.withLock { $0 }, 0)
        let waited = ContinuousClock.now - started
        XCTAssertLessThan(waited, .milliseconds(7600), "2.5 s after the last words, not the cap")
        XCTAssertGreaterThan(waited, .milliseconds(6500))
    }

    // MARK: - Helpers

    private func makeSession(
        retries: OSAllocatedUnfairLock<Int>,
        retryResult: String?,
        speechDetected: Bool = true,
        client: (any SpeechRecognizer)? = nil,
        provider: ASRProvider = .stepfun
    ) async throws -> RecognitionSession {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "test-not-used", "recognitionMode": "streaming"]))
        let session = RecognitionSession()
        await session.prepareRecordingStopForTesting(
            client: client ?? TrickleASRStub(revisions: []),
            config: config,
            provider: provider,
            speechDetected: speechDetected
        ) {
            retries.withLock { $0 += 1 }
            return retryResult
        }
        return session
    }

    private static func name(of event: RecognitionEvent) -> String {
        switch event {
        case .connectionLost: return "connectionLost"
        case .retryingFullRecording: return "retryingFullRecording"
        case .error: return "error"
        case .completed: return "completed"
        case .transcript: return "transcript"
        default: return "other"
        }
    }
}

private extension RecognitionTranscript {
    static func partial(_ text: String) -> RecognitionTranscript {
        RecognitionTranscript(confirmedSegments: [], partialText: text, authoritativeText: "", isFinal: false)
    }
}

/// Sends a few revisions after endAudio, spaced out like a slow link, and never
/// a final event. No network or credentials are used.
private actor TrickleASRStub: SpeechRecognizer {
    private let stream: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let revisions: [(Duration, String)]
    private var task: Task<Void, Never>?

    init(revisions: [(Duration, String)]) {
        (stream, continuation) = AsyncStream.makeStream()
        self.revisions = revisions
    }

    var events: AsyncStream<RecognitionEvent> { stream }
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}
    func sendAudio(_ data: Data) async throws {}
    func endAudio() async throws {
        let continuation = continuation
        let revisions = revisions
        task = Task {
            let start = ContinuousClock.now
            for (at, text) in revisions {
                try? await Task.sleep(until: start + at, clock: .continuous)
                guard !Task.isCancelled else { return }
                continuation.yield(.transcript(RecognitionTranscript(
                    confirmedSegments: [], partialText: text, authoritativeText: "", isFinal: false
                )))
            }
        }
    }
    func disconnect() async {
        task?.cancel()
        continuation.finish()
    }
}

final class TypoWaitingFaceTests: XCTestCase {
    private func thinking(network: RecordingNetworkState = .normal) -> TypoPerformance {
        var p = TypoPerformance(peek: .caret)
        p.begin(at: 0)
        p.update(level: 0.05, at: 0.5)
        p.network = network
        p.think(at: 1)
        return p
    }

    func testTypoWaitsPatientlyThenChecksItsWristThenSweats() {
        let p = thinking()
        XCTAssertEqual(p.pose(at: 1.5).expression.bubble, .question, "pondering first")
        let patient = p.pose(at: 1 + TypoPerformance.patientAfter + 0.5).expression
        XCTAssertEqual(patient.bubble, .dots)
        XCTAssertEqual(patient.eyeL, .relaxed)
        let waiting = p.pose(at: 1 + TypoPerformance.waitingAfter + 0.2).expression
        XCTAssertEqual(waiting.bubble, .hourglass)
        XCTAssertFalse(waiting.sweat)
        XCTAssertTrue(p.pose(at: 1 + TypoPerformance.sweatAfter + 0.2).expression.sweat)
    }

    func testRecognizingTheWholeRecordingAgainGetsADeterminedFace() {
        let face = thinking(network: .retrying).pose(at: 8).expression
        XCTAssertEqual(face.bubble, .retry)
        XCTAssertEqual(face.eyeL, .chevron)
    }

    func testAfterTheLineDropsTypoListensWithAHandToItsEar() {
        var p = TypoPerformance(peek: .caret)
        p.begin(at: 0)
        p.update(level: 0.05, at: 1)
        p.network = .lost
        let face = p.pose(at: 1.2).expression
        XCTAssertEqual(face.bubble, .offline)
        XCTAssertTrue(face.armR.up)
    }

    @MainActor
    func testPartlyDeliveredWordsGetASheepishFaceAndStillLandAsASuccess() {
        XCTAssertEqual(TypoDirector.reaction(for: .warning, network: .lost), .sheepish)
        XCTAssertEqual(TypoDirector.reaction(for: .warning), .failed)
        let face = TypoPerformance.face(for: .sheepish)
        XCTAssertTrue(face.sweat)
        XCTAssertTrue(face.blush)
    }
}
