import Foundation
@preconcurrency import AVFoundation
import Type4MeReviseCore

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 20
    var bypassProxy: Bool = false
    /// When set, ASR clients connect to this URL instead of their default endpoint.
    var cloudProxyURL: String?
    var customURLSessionConfiguration: URLSessionConfiguration?

    var urlSessionConfiguration: URLSessionConfiguration {
        if let custom = customURLSessionConfiguration {
            return custom
        }
        let config = URLSessionConfiguration.default
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        return config
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enablePunc == rhs.enablePunc
            && lhs.hotwords == rhs.hotwords
            && lhs.boostingTableID == rhs.boostingTableID
            && lhs.contextHistoryLength == rhs.contextHistoryLength
            && lhs.bypassProxy == rhs.bypassProxy
            && lhs.cloudProxyURL == rhs.cloudProxyURL
            && lhs.customURLSessionConfiguration === rhs.customURLSessionConfiguration
    }
}

enum ProxyBypassMode: String {
    case off, all, asr, llm

    static var current: ProxyBypassMode {
        ProxyBypassMode(rawValue: UserDefaults.standard.string(forKey: "tf_bypassProxy") ?? "off") ?? .off
    }

    var bypassASR: Bool { self == .all || self == .asr }
    var bypassLLM: Bool { self == .all || self == .llm }
}

/// A recognized word (or phrase) and when it ends in the audio, in seconds
/// from the start of the recording.
struct TimedWord: Sendable, Equatable {
    let text: String
    let end: TimeInterval

    /// A word still being said this soon after a moment belongs before it.
    static let tolerance: TimeInterval = 0.15

    /// The words said by `time`, joined; nil when the recognizer gives no timing.
    static func prefix(_ words: [TimedWord], through time: TimeInterval) -> String? {
        guard !words.isEmpty else { return nil }
        return words.prefix { $0.end <= time + tolerance }.map(\.text).joined()
    }
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool
    /// Monotonic timestamp when the ASR client emitted this transcript.
    /// Used for pipeline latency diagnostics; excluded from Equatable.
    var emitTime: ContinuousClock.Instant = .now
    /// When each word ends in the audio, if the recognizer says; it places
    /// quotes where the user was talking. Excluded from Equatable.
    var timedWords: [TimedWord] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.confirmedSegments == rhs.confirmedSegments
            && lhs.partialText == rhs.partialText
            && lhs.authoritativeText == rhs.authoritativeText
            && lhs.isFinal == rhs.isFinal
    }

    static let empty = RecognitionTranscript(
        confirmedSegments: [],
        partialText: "",
        authoritativeText: "",
        isFinal: false
    )

    var composedText: String {
        let pieces = confirmedSegments + (partialText.isEmpty ? [] : [partialText])
        return pieces.joined()
    }

    var displayText: String {
        authoritativeText.isEmpty ? composedText : authoritativeText
    }
}

enum InjectionOutcome: Sendable, Equatable {
    case inserted
    /// Cmd+V was sent to an AX-opaque editor, but insertion cannot be proven.
    /// The dictated result intentionally remains in the clipboard.
    case pasteAttemptedClipboardRetained
    case copiedToClipboard
    /// The user left the place being dictated into and it could not be
    /// brought back, so nothing was pasted; the words are in the clipboard.
    case copiedTargetGone
    /// The network broke and only the words heard before it went in; the
    /// recording is kept in history to be recognized again.
    case insertedPartial
    case notInserted
    case discarded

    var completionMessage: String {
        switch self {
        case .inserted:
            return L("已完成", "Done")
        case .pasteAttemptedClipboardRetained:
            return L(
                "已尝试输入，文本已保留到剪贴板",
                "Paste attempted; text kept in clipboard"
            )
        case .copiedToClipboard:
            return L("已粘贴到剪贴板", "Copied to clipboard")
        case .copiedTargetGone:
            return L("已复制，原输入框不在了", "Copied — the original box is gone")
        case .insertedPartial:
            return L(
                "网络不好，只识别到一部分，录音已存到历史，可重新识别",
                "Network was poor — only part was recognized. The recording is in history to try again."
            )
        case .notInserted:
            return L("未找到可输入的位置", "No editable field found")
        case .discarded:
            return L("已取消", "Cancelled")
        }
    }

    var completionHoldDuration: Duration {
        switch self {
        case .copiedToClipboard, .pasteAttemptedClipboardRetained, .notInserted:
            return .milliseconds(1500)
        case .copiedTargetGone:
            return .milliseconds(2200)
        case .insertedPartial:
            return .milliseconds(3200)
        case .discarded, .inserted:
            return .milliseconds(500)
        }
    }
}

/// Decided once per recording, when the session's provider config is resolved.
struct RecordingFinishHint: Equatable, Sendable {
    /// Whether the end of recording waits on a batch upload or a Qwen3-only final pass.
    var waitsForFullAudioRecognition: Bool
    /// SenseVoice streaming + Qwen3 final calibration.
    var performsCalibration: Bool
    /// The mode will call an LLM unless short-text exemption applies.
    var runsLLM: Bool
    /// `ProcessingMode.shortTextExemption`; 0 means disabled.
    var shortTextExemption: Int
    /// Whether the active ASR engine provides real-time streaming recognition during recording.
    var supportsRealtimeRecognition: Bool = true

    init(
        waitsForFullAudioRecognition: Bool,
        performsCalibration: Bool,
        runsLLM: Bool,
        shortTextExemption: Int,
        supportsRealtimeRecognition: Bool = true
    ) {
        self.waitsForFullAudioRecognition = waitsForFullAudioRecognition
        self.performsCalibration = performsCalibration
        self.runsLLM = runsLLM
        self.shortTextExemption = shortTextExemption
        self.supportsRealtimeRecognition = supportsRealtimeRecognition
    }
}

enum RecognitionEvent: Sendable {
    case ready
    case sessionReady(generation: UInt64)
    case finishHint(RecordingFinishHint)
    case useFinishingLabel
    case willInject
    case enterProcessing
    case transcript(RecognitionTranscript)
    case error(Error)
    case completed
    case processingResult(text: String)
    case processingLabelOverride(String)
    /// The live stream broke while recording; recording goes on.
    case connectionLost(message: String)
    /// The whole recording is being recognized again after a broken stream.
    case retryingFullRecording
    case finalized(text: String, injection: InjectionOutcome, llmFailed: Bool)
    /// Mac Action mode: action result to surface in the floating bar with
    /// status-specific icon and color, holding for ~3 seconds.
    case macActionResult(message: String, status: MacActionResultStatus)
    /// Selection ask mode: show a separate answer panel and stream Markdown into it.
    case selectionAskStarted(
        requestID: UUID,
        question: String,
        selectedText: String,
        contextWasTruncated: Bool
    )
    case selectionAskAnswerDelta(requestID: UUID, delta: String)
    case selectionAskAnswerCompleted(requestID: UUID)
    case selectionAskAnswerFailed(requestID: UUID, message: String)
    case reviseProcessing
    case reviseCompleted(text: String, message: String, undoTicketID: UUID?)
    case reviseFailed(ReviseFailure)
    case reviseCancelled
    case reviseUndone(text: String)
}

struct LLMConfig: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String
    /// User-selected `reasoning_effort` for the custom OpenAI-compatible provider; nil sends nothing.
    let reasoningEffort: String?

    init(apiKey: String, model: String, baseURL: String = "", reasoningEffort: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.reasoningEffort = reasoningEffort
    }
}

protocol SpeechRecognizer: Sendable {
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws
    func sendAudio(_ data: Data) async throws
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
    func endAudio() async throws
    func disconnect() async
    var events: AsyncStream<RecognitionEvent> { get async }
}

extension SpeechRecognizer {
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }
}
