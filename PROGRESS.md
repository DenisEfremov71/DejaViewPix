# Progress

## Current status

**Day 3 🟡 built, awaiting the live check in the simulator (2026-10-02).** Next: verify "photos from Whistler last winter" end to end, then **Day 4: Structured output, validation and cost.**

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

## Day 2: Streaming, retries and cancellation (done 2026-10-02)

**Built**
- `MessageRequest.stream` (sent only when set).
- `ServerSentEvents.swift`:
  - `SSEParser` (event and data fields, multi-line data, comments, CRLF)
  - `StreamEvent` enum: message start/delta/stop, content block start/stop, `textDelta`, `inputJSONDelta`, and a client-side `.retrying`
  - `EventStreamReader`, which throws `.streamInterrupted` when `message_stop` never arrives
  - `ping`, unknown events and unknown delta types are skipped. An `error` event throws `ClaudeError.stream(type:message:)`.
- `RetryPolicy.swift`:
  - retries 429, 5xx (including 529) and transient `URLError`s
  - 3 attempts; backoff `1s × 2^n`, scaled by 50–100% jitter and capped at 20 s
  - `retry-after` takes priority
- `ClaudeClient.stream(_:)`:
  - a `nonisolated` method that returns an `AsyncThrowingStream` fed by an unstructured task (off the main actor), reading `session.bytes(for:)` with `.lines`
  - `onTermination` cancels the task
  - injectable `endpoint`, `retryPolicy` and `sleep`
  - HTTP error construction is shared with `send` through `ClaudeClient.httpError(data:response:)`
- UI: text streams in; the metrics are tokens, time to first token, total time and stop reason; a "Server busy, retrying in X s (attempt n of 3)…" line shows during backoff.
- A DEBUG-only "Simulate overload" toggle (`DejaViewPix/Debug/SimulatedOverload.swift`): a `URLProtocol` that answers the next 2 requests with 529 and never reads the request.
- 34 tests in total:
  - parser: recorded stream, missing blank lines, CRLF, multi-line data, tool deltas, unknown events, error event, cut-off stream
  - retry policy
  - client over a `MockURLProtocol`: 529 → 529 → 200 with growing delays, `retry-after`, network errors, giving up after 3 attempts, no retry on 401, no retry after the stream starts, Cancel during an hour-long backoff ends within 1 s

**Verified:** `swift test` passes, and the app builds without warnings. In the simulator:
- text streams token by token
- "Simulate overload" shows two retries with growing delays, then the reply streams
- Cancel during the backoff stops at once
- Cancel mid-stream stops the text and keeps the partial reply

**Decisions**
- `URLSession.AsyncBytes.lines` drops blank lines, so SSE blank-line framing never fires. The parser also ends an event when a new `event:` line starts, and flushes the last one at end of stream.
- A retry happens only if no event has been yielded yet. After the first event, errors (including a mid-stream `overloaded_error` event) end the stream.
- A cancelled `AsyncThrowingStream` ends quietly instead of throwing, so the consumer calls `Task.checkCancellation()` after the loop.
- The default `sleep` is `Task.sleep`, which throws as soon as the task is cancelled, so Cancel never waits out a backoff.

**Interview answer:** "Why is retrying mid-stream dangerous?" The user has already seen part of the reply, and a retry generates a new, different reply. Appending it would duplicate or garble the text, and the input tokens would be paid twice. The client retries only before the first event arrives. After that it surfaces the error and keeps the partial text, and the user decides whether to resend.

## Day 3: PhotoKit search and the tool loop (built 2026-10-02)

**Built**
- `JSONValue.swift`: any JSON value (Codable, literal-expressible), `decode(as:)`, compact sorted `jsonString`.
- Messages API: `ContentBlock.toolUse(id:name:input:)` and `.toolResult(toolUseID:content:isError:)` (`is_error` sent only when true), `ToolDefinition` (`input_schema`), `MessageRequest.tools`, `MessageResponse.toolUses`.
- `ClaudeClient.createMessage(system:messages:tools:)`: non-streaming, full conversation, same retry policy as streaming. Conforms to the new `MessageSending` protocol.
- `PhotoSearching.swift`: the protocols `PhotoSearching` and `PlaceGeocoding`, plus `PhotoQuery`, `GeoCircle`, `PhotoMatch`, `AlbumInfo` and `Place` (whose `Kind` sets the radius: address 300 m, beach 1.5 km, city 15 km, region 200 km, country 1000 km).
- `PhotoLibrary.swift` (PhotoKit):
  - date, media type and favorite go into the predicate, sorted by `creationDate`, with `fetchLimit = limit + 1` to detect "more available"
  - location searches fetch without a limit and filter with `CLLocation.distance(from:)`
  - albums are looked up by title (user albums first, then a curated set of smart albums)
- `PlaceGeocoder.swift`: `MKGeocodingRequest` on iOS/macOS 26+, `CLGeocoder` on earlier versions (deployment target 17.5). It classifies the result (POI category, or the name compared with the city/country) to pick the radius.
- `PhotoTools.swift`: `search_photos`, `geocode_place` and `list_albums`, with JSON Schemas and descriptions written as prompts.
  - Inputs are validated: YYYY-MM-DD days in the user's time zone with an inclusive `date_to`, lat/lon/radius given together and in range, enums checked, limit clamped to 1–100.
  - Results are compact JSON: id, local date, km from the center, and video/favorite flags only when true.
- `ToolLoop.swift`:
  - `SearchPrompt.system(now:timeZone:)` includes "Today is 2026-10-02 (Friday), time zone …", plus rules for seasons and filters.
  - `ToolLoop` appends the assistant message unchanged, then one user message with a `tool_result` per `tool_use`, in order.
  - Capped at 5 requests (`ToolLoopError.roundLimitReached`). An unexpected stop reason throws.
  - Any tool error becomes `is_error: true`. Only cancellation propagates.
  - `onRound` reports progress.
- App:
  - tabs: Search (new), Chat (the Day 2 screen, now `ChatView`), API Key (`APIKeyView`)
  - `NSPhotoLibraryUsageDescription` set through the `INFOPLIST_KEY_` build setting
  - access banner for not determined, limited, denied and restricted, rechecked when the app becomes active
  - a live round-by-round trace and a thumbnail grid of the returned IDs
  - tool calls logged with OSLog (subsystem `DejaViewPix`, category `search`)
- `scripts/seed-simulator-photos.swift`: generates 9 JPEGs with EXIF dates and GPS (Whistler in winter ×3, Whistler in summer, Vancouver, Squamish, Paris, Tofino, one without GPS) and runs `simctl addmedia booted`.
- 56 tests in total. New ones cover: the Whistler round trip over a scripted client (the exact second and third request bodies, and Vancouver day boundaries), a failing tool returned as `is_error`, an unknown tool, bad input, several calls in one turn, the 5-round cap, `max_tokens`, cancellation inside a tool, input validation cases, JSONValue, tool block encoding, the PhotoKit predicate and place classification.

**Verified:** `swift test` passes (56 tests), and the app builds without warnings. Not yet verified: the real query in the simulator.

**Decisions**
- The loop is non-streaming. Tool rounds are short and need the whole reply anyway; streaming the final answer can come later.
- Tool errors are caught in the loop, not in each tool, so no tool implementation can crash the loop.
- Location is three flat fields (`latitude`, `longitude`, `radius_meters`) rather than a nested object, which is easier for the model to fill.
- Results carry no reverse-geocoded place names. That would mean a network call per photo; the distance in km is cheaper and enough for the model.

**Interview answer:** "Walk me through one tool-calling round trip. What exactly goes into the second request?" The second request carries the same model, system prompt and tools. Its messages are: the original user message; Claude's assistant message unchanged, with its text and `tool_use` blocks (id, name, input); then a new user message with one `tool_result` block per `tool_use`, matched by `tool_use_id`, with the tool's output as content and `is_error: true` on failures. The API is stateless, so the whole conversation is resent each round, and input tokens grow with every round.

## Open items

- Live check of Day 3 in the simulator: "photos from Whistler last winter" should call geocode_place, then search_photos with Dec 2025–Feb 2026 and about 15 km, and return the 3 winter Whistler photos.
