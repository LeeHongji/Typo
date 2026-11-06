import AppKit
import ImageIO
import SwiftUI

/// What the history list says about quotes, screenshots and unfinished
/// recordings, in the current language.
enum HistoryAttachmentCopy {
    static var quotes: String { L("引用", "Quotes") }
    static var screenshots: String { L("截图", "Screenshots") }
    static var cleared: String { L("已清理", "Cleared") }
    static var copy: String { L("复制", "Copy") }
    static var recognizeAgain: String { L("重新识别", "Recognize again") }
    static var recognizing: String { L("正在识别…", "Recognizing…") }
    static var stillFailed: String { L("还是没能识别，录音仍保留", "Still couldn't recognize it; the recording is kept") }
    static var recognizedAgain: String { L("已重新识别，结果已复制", "Recognized again; the words are copied") }
    static var partial: String { L("网络中断，只识别到一部分", "Network broke; only part was recognized") }
    static var unrecognized: String { L("（网络中断，没能识别，录音已保存）", "(Network broke; not recognized — recording kept)") }

    static func quoteCount(_ n: Int) -> String { L("\(n) 段引用", "\(n) quote\(n == 1 ? "" : "s")") }
    static func screenshotCount(_ n: Int) -> String { L("\(n) 张截图", "\(n) screenshot\(n == 1 ? "" : "s")") }
}

enum HistoryQuotedText {
    /// The entry's words with each quote marked where it went in, as on the bar.
    @MainActor
    static func attributed(_ text: String, quotes: [HistoryAttachments.Quote], hasRecording: Bool = false) -> AttributedString {
        if text.isEmpty, hasRecording {
            var placeholder = AttributedString(HistoryAttachmentCopy.unrecognized)
            placeholder.foregroundColor = .secondary
            return placeholder
        }
        guard !quotes.isEmpty else { return AttributedString(text) }
        var out = AttributedString()
        var cursor = text.startIndex
        for quote in quotes.sorted(by: { $0.offset < $1.offset }) {
            let at = text.index(text.startIndex, offsetBy: min(max(0, quote.offset), text.count))
            if cursor < at {
                out += AttributedString(String(text[cursor..<at]))
                cursor = at
            }
            out += LiveQuoteMark.attributed(AttachmentPreview.short(quote.text, limit: 18))
        }
        if cursor < text.endIndex { out += AttributedString(String(text[cursor...])) }
        return out
    }
}

/// The small counts beside an entry's other details.
struct HistoryAttachmentBadges: View {
    let attachments: HistoryAttachments
    @AppStorage("tf_language") private var language = AppLanguage.current.rawValue

    var body: some View {
        let _ = language
        if !attachments.quotes.isEmpty {
            Label(HistoryAttachmentCopy.quoteCount(attachments.quotes.count), systemImage: "text.quote")
        }
        if !attachments.screenshots.isEmpty {
            Label(HistoryAttachmentCopy.screenshotCount(attachments.screenshots.count), systemImage: "photo")
        }
        if attachments.recording != nil {
            Label(HistoryAttachmentCopy.partial, systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}

/// An expanded entry's quotes, screenshots and, for an unfinished dictation,
/// the way to recognize its recording again.
struct HistoryAttachmentsDetails: View {
    let record: HistoryRecord
    let attachments: HistoryAttachments
    var media: HistoryMediaStore = HistoryStore.shared.media
    @AppStorage("tf_language") private var language = AppLanguage.current.rawValue
    @State private var recognizing = false
    @State private var outcome: String?

    var body: some View {
        let _ = language
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.quotes.isEmpty {
                section(HistoryAttachmentCopy.quotes) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(attachments.quotes.enumerated()), id: \.offset) { _, quote in
                            quoteBlock(quote.text)
                        }
                    }
                }
            }
            if !attachments.screenshots.isEmpty {
                section(HistoryAttachmentCopy.screenshots) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.screenshots.enumerated()), id: \.offset) { _, shot in
                                thumbnail(shot)
                            }
                        }
                    }
                }
            }
            if let file = attachments.recording, media.exists(id: record.id, file: file) {
                recognizeAgainRow
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
            content()
        }
    }

    private func quoteBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: AttachmentEffects.accent))
                .frame(width: 3)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.tfIcon(.plain))
            .help(HistoryAttachmentCopy.copy)
            .accessibilityLabel(HistoryAttachmentCopy.copy)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: AttachmentEffects.accent).opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func thumbnail(_ shot: HistoryAttachments.Screenshot) -> some View {
        let url = media.url(for: record.id, file: shot.file)
        let height: CGFloat = 64
        let width = min(160, max(48, height * CGFloat(shot.width) / CGFloat(max(shot.height, 1))))
        if let image = HistoryThumbnails.image(at: url) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(TF.settingsBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("\(shot.width) × \(shot.height)")
            .accessibilityLabel(HistoryAttachmentCopy.screenshots)
        } else {
            Text(HistoryAttachmentCopy.cleared)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(width: width, height: height)
                .background(TF.settingsBorder.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var recognizeAgainRow: some View {
        HStack(spacing: 8) {
            Button {
                recognizing = true
                outcome = nil
                Task {
                    let text = await RecognitionSession.recognizeAgain(record: record)
                    if let text {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    recognizing = false
                    outcome = text == nil ? HistoryAttachmentCopy.stillFailed : HistoryAttachmentCopy.recognizedAgain
                }
            } label: {
                if recognizing {
                    HStack(spacing: 5) {
                        TFSpinner()
                        Text(HistoryAttachmentCopy.recognizing)
                    }
                } else {
                    Label(HistoryAttachmentCopy.recognizeAgain, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.tf(.secondary, size: .small))
            .disabled(recognizing)
            if let outcome {
                Text(outcome)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
    }
}

/// Screenshot thumbnails for the history list, decoded once at list size.
@MainActor
enum HistoryThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
