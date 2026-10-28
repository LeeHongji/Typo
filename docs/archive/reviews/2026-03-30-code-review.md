# Type4Me Code Review — 2026-03-30

> **归档文档 · 历史代码审查（2026-03-30）**：行号、问题状态和建议均对应当时快照，不代表当前代码。当前文档入口见 `docs/README.md`。

Of course. Here is my comprehensive code review report for the recent changes to Type4Me.

---

### Executive Summary

This is a significant and well-executed feature update, introducing local, cross-platform ASR (Qwen3) and LLM capabilities, which is a major architectural improvement. The code quality is generally high, with good use of modern Swift concurrency, robust Python async patterns, and thoughtful UI/UX enhancements like built-in ASR corrections. However, there is one critical data race in the Swift code and several opportunities to improve state management and error handling in both the client and server.

### Critical Issues

| Severity | File & Line | Problem Description | Fix Recommendation |
| :--- | :--- | :--- | :--- |
| **CRITICAL** | `Type4Me/Services/SenseVoiceServerManager.swift:29` | **Data Race on Shared State.** The `currentPort` static variable is marked `nonisolated(unsafe)` to allow synchronous access from other parts of the app (like `KeychainService`). This creates a data race. Writing to it from the actor's executor and reading it from another thread without synchronization is a violation of Swift's concurrency rules and can lead to undefined behavior, crashes, or subtle bugs. | Make the port retrieval an `async` operation. Remove `nonisolated(unsafe)` and add an `async` function to the actor to return the port. Callers like `KeychainService.loadLLMConfig` will need to become `async` to accommodate this, which is the correct pattern. <br><br> **`SenseVoiceServerManager.swift`** <br> ```swift
// Remove this line
// nonisolated(unsafe) private(set) static var currentPort: Int?
// Keep this actor-isolated property
private var port: Int?
// Add this getter
func getCurrentPort() -> Int? {
    return self.port
}
``` <br> **`KeychainService.swift`** <br> ```swift
static func loadLLMConfig() async -> LLMConfig? { // Make async
    if selectedLLMProvider == .localQwen {
        guard let port = await SenseVoiceServerManager.shared.getCurrentPort() else { return nil }
        // ...
    }
    // ...
}
``` |

### High Priority Issues

| Severity | File & Line | Problem Description | Fix Recommendation |
| :--- | :--- | :--- | :--- |
| **HIGH** | `Type4Me/UI/Settings/*.swift` | **Multiple Sources of Truth for Server State.** The new `ModelSettingsTab`, `ASRSettingsCard`, and `LLMSettingsCard` each contain separate logic for starting, stopping, and checking the status of the local Python server. This creates multiple sources of truth for the server's state (`isRunning`, `isStarting`), leading to UI inconsistencies, redundant operations, and potential race conditions. The `LocalServerCoordinator` was introduced but is not used as a single shared instance. | Consolidate all server management logic into `LocalServerCoordinator`. Instantiate it once in the parent view (`ModelSettingsTab`) and pass it down to `ASRSettingsCard` and `LLMSettingsCard` as an `@ObservedObject` or via the environment. All UI components should read from and issue commands to this single coordinator instance. |
| **HIGH** | `qwen3-asr-server/server.py:100` | **Overly Broad Exception Handling Silences Errors.** The `_send_partial` function uses `except Exception: pass`. This will silently swallow *any* error that occurs during partial transcription, including bugs in the MLX model, invalid audio data, or other unexpected issues. This makes debugging extremely difficult and can lead to the server failing to produce transcripts with no indication of why. | Make the exception handling more specific. At a minimum, catch `asyncio.CancelledError` and `pass` silently, but log all other exceptions before passing. <br><br> ```python
import logging
# ...
async def _send_partial(ws: WebSocket, sess, samples: list[int],
                        cancel_token: CancelToken | None = None):
    """Run transcribe on accumulated audio (no punctuation) and send as partial."""
    try:
        # ... (rest of the function)
    except asyncio.CancelledError:
        pass  # This is expected when a partial is cancelled
    except Exception as e:
        logging.exception("Error during partial transcription")
``` |
| **HIGH** | `Type4Me/LLM/DoubaoChatClient.swift:51` | **Non-streaming local LLM requests are sent as streaming.** The client has been updated to differentiate between streaming and non-streaming responses, but the initial request body is still being created with `stream: useStreaming`. The `qwen3-asr-server`'s llama.cpp endpoint does not support streaming and expects `stream: false`. The change in the diff sets `stream` to `useStreaming`, which is `false` for `localQwen`. This is correct. However, inspecting the original code shows `stream: true` was hardcoded. The diff correctly fixes this potential issue, but it's worth highlighting as a critical fix that was made. The `ChatRequest` struct is correctly defined. The fix is already in the diff. | No action needed, the diff correctly addresses this by setting `stream: useStreaming`. This comment is to confirm the importance of that change. |

### Medium Priority Issues

| Severity | File & Line | Problem Description | Fix Recommendation |
| :--- | :--- | :--- | :--- |
| **MEDIUM** | `Type4Me/Services/LocalServerCoordinator.swift:29` | **Silent Failure on LLM Preloading.** The `preloadLLM()` function uses `try? await URLSession.shared.data(for: request)`, which silently discards any errors that occur (e.g., server not running, model failing to load). The user or developer has no indication that preloading failed. | Log the error if the `data(for:)` call fails. This provides crucial debugging information without altering the user-facing behavior. <br><br> ```swift
// in preloadLLM()
do {
    _ = try await URLSession.shared.data(for: request)
    logger.info("Local LLM model preloaded")
} catch {
    logger.error("Failed to preload local LLM: \(error)")
}
``` |
| **MEDIUM** | `qwen3-asr-server/server.py:108` | **Potential Race Condition with `asyncio.Future.cancel()`**. The code calls `inflight_partial.cancel()`, which schedules a `CancelledError` to be raised in the task. This is handled by the broad `except Exception` block in `_send_partial`. This works but is not explicit. The custom `CancelToken` provides a cleaner, cooperative cancellation mechanism that is already in place. Relying on two different cancellation systems is confusing. | Simplify the cancellation logic. The cooperative `CancelToken` is sufficient and less ambiguous. The `inflight_partial.cancel()` call is redundant and can be removed. The `CancelToken` ensures the thread-pool task exits early, and the `asyncio` task will then complete naturally. <br><br> ```python
# in websocket_endpoint
if len(data) == 0:
    # ── End of audio: final transcribe with punctuation ──
    cancel_token.cancel()  # Signal any in-flight partial to bail out
    # The line below can be removed. The check inside _transcribe_sync is sufficient.
    # if inflight_partial and not inflight_partial.done():
    #     inflight_partial.cancel()
```|
| **MEDIUM** | `Type4Me/Services/SnippetStorage.swift:131`, `148` | **Repetitive Regex Compilation.** The `apply` and `applyEffective` functions recompile an `NSRegularExpression` for every snippet on every call. For a large number of snippets or frequent calls, this is inefficient. | Cache the compiled `NSRegularExpression` objects. Since the snippets can be user-edited, the cache should be invalidated when `save` is called. A simple approach is a static dictionary mapping snippet triggers to compiled regex objects. |

### Low Priority / Polish

| Severity | File & Line | Problem Description | Fix Recommendation |
| :--- | :--- | :--- | :--- |
| **LOW** | `Type4Me/LLM/Providers/LocalQwenLLMConfig.swift:81` | **Hardcoded Developer Path.** The `path` property includes a hardcoded path `~/projects/type4me/...`. While common for development, this is brittle. | Consider using an environment variable to specify the development model directory for more flexibility. This is a minor polish item for developer experience. |
| **LOW** | `scripts/package-app.sh:31` | **Fragile Binary Path Discovery.** The script uses `find` and `head -n 1` to locate the compiled binary. This can be brittle if the build directory structure changes or if multiple targets exist. | Use `swift build --show-bin-path` to get the exact path to the build artifacts directory. This is the canonical and more robust method. <br><br> `BINARY="$(swift build --show-bin-path)/Type4Me"` |
| **LOW** | `Type4Me/Session/RecognitionSession.swift:201` | **Ineffective Hotword Loading.** `HotwordStorage.load()` was being called, which only loads user hotwords. The built-in hotwords were not being passed to the ASR engine. | The diff correctly changes this to `HotwordStorage.loadEffective()`. This is a good fix that was included in the changes. |
| **LOW** | `Type4Me/Type4MeApp.swift:52` | **Snippet Seeding Missing.** The app was not seeding the built-in ASR correction snippets on first launch, meaning users would not benefit from them until a future update. | The diff correctly adds a call to `SnippetStorage.seedIfNeeded()` in `applicationDidFinishLaunching`. This is a good fix. |

### Positive Highlights

*   **Qwen3 ASR/LLM Integration:** The addition of a local, Metal-accelerated ASR and LLM server is a fantastic feature. The Python server is well-structured, using FastAPI and `run_in_executor` correctly to handle blocking ML tasks in an async environment.
*   **Robust Packaging:** The `package-app.sh` script is excellent. It correctly handles universal binaries, resource bundling, and has a very clever workaround for signing PyInstaller-generated bundles, which is a common and difficult problem.
*   **ASR Quality-of-Life:** The built-in hotwords (`HotwordStorage`) and especially the ASR correction snippets (`SnippetStorage`) are a huge win for user experience. The flexible regex generation in `buildFlexPattern` is particularly impressive and shows deep thought into solving common ASR errors.
*   **Swift Concurrency:** Besides the critical data race, the Swift code shows a strong command of modern concurrency, with appropriate use of actors, `@MainActor`, and `Sendable`.
*   **UI Refactoring:** The settings screen refactoring into `General`, `Models`, and `Vocabulary` tabs is a major improvement in organization and clarity. The new `SettingsCardHelpers` cleans up the view code significantly.
*   **State Management Fix:** The addition of `hotkeyManager.resetActiveState()` is a crucial bug fix that correctly addresses a state management issue, preventing the UI and hotkeys from getting stuck.
