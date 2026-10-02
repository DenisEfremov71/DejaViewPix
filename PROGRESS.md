# Progress

## Current status

**Day 1 ✅ complete (2026-10-01).** Next: **Day 2: streaming, retries and cancellation.**

## Day 1: Project setup and first API call (done 2026-10-01)

**Built**
- Xcode app `DejaViewPix`, SwiftUI, iOS 17.5, display name "Deja View Pix".
- Local Swift package `AlbumAI`, linked to the app:
  - `MessagesAPI.swift`: `MessageRequest` (model, max_tokens, optional system, messages with content-block arrays), `MessageResponse`, `Usage`. `ContentBlock` is an enum with `.text` and `.unknown(type:)`, so new block types decode without crashing. Encoding an `.unknown` block throws.
  - `ClaudeClient.swift`: `actor ClaudeClient`, which returns `ClaudeReply` (text, stop reason, usage, latency via `ContinuousClock`, request ID). Maps `URLError.cancelled` to `CancellationError`. `ClaudeModel` enum: haiku (default), sonnet 5.5, opus 5.5, and a deliberately invalid model for testing errors.
  - `ClaudeError.swift`: `.http(status:type:message:requestID:retryAfter:)`, `.invalidResponse`, `.noTextContent(stopReason:)`.
  - `APIKeyStore.swift`: Keychain generic password, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Throwaway screen: key field with Save, prompt field, Send/Cancel, metrics panel (tokens, latency, stop reason, request ID).
- 10 unit tests (Swift Testing) for encoding, headers, decoding, typed errors and readable messages.

**Verified:** a real prompt returns a reply with metrics. A wrong key shows "HTTP 401, authentication_error". Cancel stops a request in flight. `swift test` passes.

**Decisions**
- Key injected into the client as a `@Sendable () throws -> String` closure, so the package doesn't depend on where the key is stored.
- `makeURLRequest` and `makeReply` are static and internal, so tests check request building and response handling without the network.
- The earlier Info.plist/xcconfig key setup was removed. Lesson learned: with a synchronized folder group, a loose `.xcconfig` gets copied into the app bundle.

**Notes**
- The API sends no `request-id` header on 401 responses. The request is rejected before an ID is assigned.
- Interview answer to prepare: "Why no SDK, and how would you keep the key off devices in production?" No official Swift SDK, and the API is one HTTP endpoint. In production, a backend proxy holds the key and adds user authentication and rate limits.

## Day 2: Streaming, retries and cancellation (next)

Not started.

## Open items

- None.
