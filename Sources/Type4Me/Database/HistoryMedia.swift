import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a history entry brought in besides its words. Stored as small,
/// versioned JSON next to the entry; the files it names live in the media store.
struct HistoryAttachments: Codable, Equatable, Sendable {
    struct Quote: Codable, Equatable, Sendable {
        var text: String
        /// Characters into the entry's final text where the quote went in.
        var offset: Int
    }

    struct Screenshot: Codable, Equatable, Sendable {
        var file: String
        var width: Int
        var height: Int
    }

    var version = 1
    var quotes: [Quote] = []
    var screenshots: [Screenshot] = []
    /// The recording of a dictation the network kept from being fully
    /// recognized, so it can be recognized again from history.
    var recording: String?

    var isEmpty: Bool { quotes.isEmpty && screenshots.isEmpty && recording == nil }

    var json: String? {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> HistoryAttachments? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HistoryAttachments.self, from: data)
    }
}

/// The files that belong to history entries: screenshots, compressed to a
/// fraction of their size, and the recordings of unfinished dictations. One
/// folder per entry, removed with it. Kept small: screenshots are at most
/// `imageMaxSide` on the long side, recordings expire after a week, and past
/// `byteLimit` the oldest screenshots make room (the entry shows they were cleared).
struct HistoryMediaStore: Sendable {
    let root: URL

    static let imageMaxSide = 1280
    static let imageQuality = 0.5
    static let byteLimit = 300 * 1024 * 1024
    static let recordingLifetime: TimeInterval = 7 * 86_400
    static let recordingFile = "recording.m4a"

    func folder(for id: String) -> URL {
        root.appendingPathComponent(Self.safeName(id), isDirectory: true)
    }

    func url(for id: String, file: String) -> URL {
        folder(for: id).appendingPathComponent(Self.safeName(file))
    }

    func exists(id: String, file: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id, file: file).path)
    }

    // MARK: - Writing

    /// Saves a compressed copy of a screenshot (HEIC, JPEG where HEIC can't be written).
    func saveScreenshot(from source: URL, id: String, index: Int) -> HistoryAttachments.Screenshot? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.imageMaxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let folder = folder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (type, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let name = "screenshot-\(index).\(ext)"
            let url = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Self.imageQuality] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return HistoryAttachments.Screenshot(file: name, width: image.width, height: image.height)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return nil
    }

    /// Saves 16 kHz mono 16-bit PCM as AAC, about 200 KB a minute.
    func saveRecording(pcm: Data, id: String) -> String? {
        guard pcm.count >= 2,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        else { return nil }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let channel = buffer.int16ChannelData?[0] {
                memcpy(channel, base, Int(frames) * 2)
            }
        }
        let folder = folder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.recordingFile)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        } catch {
            DebugFileLogger.log("history media: recording not saved \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Self.recordingFile
    }

    /// Reads a saved recording back as 16 kHz mono 16-bit PCM.
    func loadRecording(id: String, file: String) -> Data? {
        let url = url(for: id, file: file)
        guard let audio = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
              audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
        else { return nil }
        do { try audio.read(into: buffer) } catch { return nil }
        guard let channel = buffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(buffer.frameLength) * 2)
    }

    // MARK: - Removing

    func remove(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    func remove(file: String, id: String) {
        try? FileManager.default.removeItem(at: url(for: id, file: file))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Recordings past their week go; past the size limit, the oldest
    /// screenshots go too. Folders no entry knows about are removed.
    func prune(knownIDs: Set<String>, now: Date = Date(), byteLimit: Int = Self.byteLimit) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for folder in folders {
            guard knownIDs.contains(folder.lastPathComponent) else {
                try? fm.removeItem(at: folder)
                continue
            }
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
                let values = try? file.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? now
                if file.lastPathComponent == Self.recordingFile, now.timeIntervalSince(date) > Self.recordingLifetime {
                    try? fm.removeItem(at: file)
                    continue
                }
                files.append((file, values?.fileSize ?? 0, date))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > byteLimit {
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }

    private static func safeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" })
    }
}
