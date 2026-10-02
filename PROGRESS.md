# Progress

## Current status

**Day 6 ✅ done (2026-10-02).** Next: **Day 7: the eval runner and unit tests.**

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

## Day 3: PhotoKit search and the tool loop (done 2026-10-02)

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

**Verified:** `swift test` passes (56 tests), and the app builds without warnings. In the simulator, "photos from Whistler last winter" ran end to end against the real API and photo library and returned real asset IDs.

**Decisions**
- The loop is non-streaming. Tool rounds are short and need the whole reply anyway; streaming the final answer can come later.
- Tool errors are caught in the loop, not in each tool, so no tool implementation can crash the loop.
- Location is three flat fields (`latitude`, `longitude`, `radius_meters`) rather than a nested object, which is easier for the model to fill.
- Results carry no reverse-geocoded place names. That would mean a network call per photo; the distance in km is cheaper and enough for the model.

**Interview answer:** "Walk me through one tool-calling round trip. What exactly goes into the second request?" The second request carries the same model, system prompt and tools. Its messages are: the original user message; Claude's assistant message unchanged, with its text and `tool_use` blocks (id, name, input); then a new user message with one `tool_result` block per `tool_use`, matched by `tool_use_id`, with the tool's output as content and `is_error: true` on failures. The API is stateless, so the whole conversation is resent each round, and input tokens grow with every round.

## Day 4: Structured output, validation and cost (done 2026-10-02)

**Built**
- `present_results` tool (`SearchAnswer.toolDefinition`): `summary` plus `photo_ids`, `strict: true`, `tool_choice` left at `auto`. The system prompt tells Claude to always finish with it.
- `SearchAnswer` (summary, photo IDs, filters) and `AppliedFilters`, with a readable `label`.
- `SearchAnswer.validated(input:calls:)`:
  - non-empty summary
  - duplicate IDs dropped
  - every ID must appear in a successful `search_photos` result; otherwise the error names the invented IDs
- Applied filters are rebuilt from the `search_photos` calls that produced the presented photos (all successful searches when nothing matched). Defaults are filled in, and the place name comes from the `geocode_place` result with matching coordinates. The model never reports filters.
- Loop changes:
  - It ends on a valid `present_results` call.
  - One correction is allowed: an invalid answer goes back as `tool_result` with `is_error: true`, and a prose `end_turn` gets a one-line user nudge. A second bad ending throws `ToolLoopError.invalidAnswer` or `.noAnswer`.
  - `present_results` alongside other tools in the same turn gets an error result.
  - `onRound` now fires before every throw, so failed searches can still be costed.
- `Usage` decodes the cache token fields (missing or null count as 0) and has `+`. `MessageResponse.model` is decoded, and `ToolDefinition.strict` is sent only when set.
- Price table in config: `AlbumAI/Sources/AlbumAI/Resources/pricing.json`, a package resource that ships in the app as `AlbumAI_AlbumAI.bundle`.
  - Copied from the official pricing page on 2026-10-02, in USD per million tokens (input / output / 5-min cache write / cache read): Haiku 4.5 1 / 5 / 1.25 / 0.10, Sonnet 5.5 2 / 10 / 2.50 / 0.20, Opus 5.5 4 / 20 / 5 / 0.20.
  - `PriceTable.price(for:)` matches dated IDs to their alias, so `claude-haiku-4-5-20251001` uses the `claude-haiku-4-5` row.
- `QueryMetrics`: model (as reported by the API), rounds, wall-clock latency, summed tokens and cost.
  - `logLine(outcome:)` produces, e.g., `claude-haiku-4-5-20251001 · 3 rounds · 4.21 s · 3600 in / 240 out tokens · $0.004800 · ok, 3 photos`.
- App:
  - logs that line once per query with OSLog `notice` (successes, errors and cancellations); the query text is `.private`
  - shows the summary, the applied filters, the thumbnails and the cost
- 70 tests. New ones cover: the Whistler run ending in `present_results` with rebuilt filters and place name, an invented ID corrected once, a second invalid answer failing, IDs with no successful search, an empty summary, a prose ending nudged once, a second prose ending failing, `present_results` mixed with other tools, filters taken only from contributing searches, `strict` encoding, the price table and alias matching, cost across all token kinds, cache fields decoding, and the log line.

**Verified:** `swift test` passes (70 tests), the app builds without warnings, and `pricing.json` is in the app bundle. Live in the iPhone 17 simulator (Haiku 4.5), each query produced a validated result and one usage line:

| Query | Rounds | Tokens in / out | Cost | Result |
|---|---|---|---|---|
| Photos from Whistler | 3 (geocode → search → present) | 5918 / 402 | $0.0079 | 4 photos (no season in the query, so the July one is correct) |
| Photos from Tokyo | 3 | 5673 / 293 | $0.0071 | 0 photos, clean "nothing found" summary |
| my favorite videos | 3 (search → prose → present) | 5582 / 195 | $0.0066 | 0 photos. Round 2 ended in prose; the nudge worked and round 3 called `present_results` |

**Finding:** a typical query costs about $0.007, and input is about 94% of the tokens. The system prompt, the tools and the growing conversation are resent each round, so a 3-round query costs about 3× a single call. Prompt caching (system plus tools) is the obvious lever.

**Decisions**
- **A `present_results` tool instead of `output_config.format`.** Native structured output is GA (no beta header) on Haiku 4.5, Sonnet 5.5 and Opus 5.5, and it works alongside tools (only the final text is constrained). The tool was chosen because:
  - The correction step stays inside the tool protocol: the error goes back as a `tool_result` tied to that call.
  - The answer is a tool call like the searches, so one loop handles everything.
  - It works the same on all three Day 8 models.
  - The cost: Opus 5.5 and Sonnet 5.5 reject a forced `tool_choice` (`any`/`tool`) with a 400, so the loop can't force the call. Claude can end in prose instead, which the nudge covers. `strict: true` still guarantees the input shape whenever the tool is called.
- The date-order check (`date_from` on or before `date_to`) is enforced where the search runs (`search_photos` input validation, Day 3), and the reported filters come only from calls that passed it. The final-answer check therefore focuses on what a schema can't catch: IDs that no search returned.
- Cost counts every round of the conversation, including the correction round. A failed search is still logged with its cost.

**Interview answer:** "How do you stop a model from returning photo IDs that don't exist?" The model never gets the last word on IDs:
1. Every `search_photos` result is recorded on the client.
2. The final answer arrives through a strict `present_results` tool, so its shape is guaranteed.
3. Each returned ID is checked against the set of IDs that successful searches actually produced.
4. Unknown IDs go back once as an `is_error` `tool_result` naming them, so the model can correct itself. A second failure is a clean error, never a grid of made-up photos.

The filters shown to the user are rebuilt from the tool calls that ran, not taken from the model's description of what it did.

## Day 5: The SwiftUI experience (done 2026-10-02)

**Built**
- Package:
  - `ToolLoop.run(onToolStart:)` fires before each tool runs. It sits after `onRound`, so a single trailing closure still binds to `onRound`.
  - `ToolCallStart.statusLine()` turns a tool call into a status line:
    - "Finding Tofino…" for `geocode_place`
    - "Searching favorite videos from July–August 2025 near Tofino…" for `search_photos`, with the place named from the earlier `geocode_place` result
    - "Checking your albums…" and "Putting your results together…" for the other two tools
  - `DateRangeText` formats whole months, years, single days, ranges and open ranges. Bounds are inclusive and the calendar is UTC.
  - `FilterChip` (dates, place + radius, media type, favorites, album, oldest first) with `label` and `systemImage`. `AppliedFilters.chips` lists them, and `[AppliedFilters].replacing(_:with:)` removes or edits a chip in every search that has it, then drops searches that became identical.
  - `PhotoTools.search([AppliedFilters])` re-runs the filters on the library with no model call. It uses the same validation as the tool, and an empty filter list means the whole library.
  - `PhotoLibrary.details(for:)` returns a `PhotoDetails` (date, video/favorite, duration, location) per ID, off the main actor.
  - `[AppliedFilters].placeName(latitude:longitude:)` names the place for VoiceOver without reverse geocoding.
- App:
  - `SearchModel` is `@Observable`, with `Phase`: idle, searching(status), results, empty, failed.
    - A generation counter keeps stale searches and edits from overwriting newer state.
    - `finishedSubmission` stops `.task(id:)` from paying for a search again when the screen reappears.
  - `PhotoSearchView`:
    - The access state picks the screen. Searches run through `.task(id: submission)`: a new submission cancels the old search, and Cancel sets it to nil.
    - Idle shows suggestions. Searching shows the status line and Cancel. Empty and Failed have their own screens.
    - A "Details" section shows the round trace (including prose rounds) and the cost.
  - `FilterChipsView`:
    - Tapping a chip opens a menu: change dates (sheet), radius picker, photos ↔ videos, or remove. The × removes in one tap.
    - Chips sit in a custom `FlowLayout`, so they wrap at large Dynamic Type sizes.
    - After an edit, the summary is replaced by "Filters edited. Searched on your iPhone, without Claude."
  - `PhotoGrid`:
    - A `LazyVGrid` with about 110 pt columns (at least 3), and a target size in pixels that matches the cell.
    - `ThumbnailLoader` is a nonisolated class around `PHCachingImageManager`. Its asset fetches are `@concurrent`, it caches the whole result set, and it delivers images opportunistically (a quick low-quality one, then the final one) through an `AsyncStream`.
    - Each cell runs one `.task(id: photo + size)`; cancelling it cancels the PhotoKit request, so a late image can't land in a reused cell.
    - VoiceOver label: "Photo, February 7, 2026 at 1:15 PM, near Whistler".
  - Permission flow:
    - An intro screen before the system prompt, explaining what Claude sees: the query plus the IDs, dates and distances of matching photos, never the photos themselves.
    - A designed denied screen with Open Settings, and a restricted screen.
    - A limited-access banner with "Select More Photos" (`presentLimitedLibraryPicker`).
- 87 tests. New ones cover date range text, status lines (including the order the loop reports them in), chips, replacing and merging chips, place names, and local re-runs (the query sent to the library, merging, the whole library).

**Verified (iPhone 17 simulator):**
- "photos from Whistler last winter": status lines "Reading your request…", "Finding Whistler…", …, then the summary, chips "December 2025–February 2026" and "Whistler · 15 km", and 3 thumbnails with VoiceOver labels.
- Removing the date chip showed 4 photos at once. The console logged `filters edited · 4 photos · no model call`.
- "my favorite videos" showed the empty screen with Videos and Favorites chips. Removing Favorites and switching Videos to Photos showed all 15 photos, with no model call.
- The intro and denied screens look right. At the largest accessibility text size, the chips wrap without truncation.
- `swift test` passes, and the app builds without warnings.

**Verified on a real iPhone:** the user ran it on their own iPhone against the device checklist (smooth grid, instant chip edits, every access state) and reported that it works.

**Decisions**
- Edits re-run the filters locally instead of asking Claude again. It's instant and free, and the user stays in control. Claude's summary is hidden after an edit, because it no longer describes what's shown.
- Only changes between phases animate. Edits within the results update the grid immediately; a crossfade made them look slow.
- Status lines come from tool inputs, not the model's text. Text shown alongside a tool call can claim things that haven't happened.

**Interview answer:** "Why do you show the parsed filters to the user instead of just the results?" Because the model can misread the query, and an unexplained grid hides that. Chips make the interpretation visible: "December 2024–February 2025 · Whistler · 15 km" tells the user at once that "last winter" was read as the wrong year. They also make it fixable in one tap without another model call, which costs nothing and takes no time. That builds trust: the user sees what the app did and stays in control, rather than wondering why their photos are missing.

## Day 6: The eval dataset (done 2026-10-02)

**Built**
- `evals/cases.json`: 30 cases (25 dev, 5 held-back test). Each has an id, split, query, expected `search_photos` arguments (dates, place, media type, favorites, album), an optional `behavior`, tags and a note. Defaults: today is 2026-10-02 (Friday), time zone America/Vancouver, place tolerance 25 km.
  - simple 5, relative dates 8, misspellings 3, ambiguous places 3, combined 3, albums 3, favorites 1, impossible 2, out of scope 1, injection 1
  - test split: `simple-05`, `rel-06`, `typo-03`, `combo-03`, `album-03`
- The user reviewed the judgment calls (hemisphere, last winter in January, Victoria/Springfield, generic "photos", date tolerances, injection) and kept them as written.
- `evals/README.md`: what is scored and why, the per-field matching rules, the three behaviors (`search`, `no_photos`, `no_search`), how the cases were chosen, and the test split policy.

**Decisions**
- Score the arguments of the first valid `search_photos` call, not the returned photos. That avoids labelling a photo library, and our own code turns correct arguments into correct photos.
- Dates are exact by default (the system prompt defines seasons), with ±1 day only for holidays, "last weekend" and "past two weeks".
- Places are scored by coordinates (within 25 km, wider for regions), not by string.
- "Photos" and "pictures" accept `media_type` null or `"photo"`. Filters the user didn't ask for fail.
- Ambiguous places: context decides when it can (Victoria from Vancouver → BC, from Melbourne → Australia); otherwise any main candidate passes (Springfield).
- The user's time zone sets the hemisphere when no place is named (`rel-07`). The current prompt doesn't do this yet, on purpose.

**Interview answer:** "How did you build an eval set without labelling thousands of real photos?" By scoring the step that's uncertain, not the whole pipeline. The model's only job is to turn a sentence into search arguments. PhotoKit and the geocoder are deterministic and unit-tested. So each case is a query plus the arguments a careful person would choose, written before running anything, with matching rules decided up front (exact dates, coordinates within a distance, accepted alternatives for genuinely ambiguous queries). The cases cover one failure mode each rather than many phrasings of one, and the same query under different "today" and time-zone contexts shows whether the model reasons or pattern-matches. Five cases are held back and only run once at the end.

## Open items

- Haiku once read "last winter" as December 2024–February 2025 (on 2026-10-02 the answer is December 2025–February 2026); another run of the same query got it right. Covered by eval cases `rel-02`, `rel-03` and `typo-01`; one possible Day 8 fix is computing the season's dates in the system prompt.
- Switching tabs mid-search cancels the search (`.task` ends when the view disappears) and runs it again when the user returns. That's acceptable, but it could keep running instead.
- The bundle ID changed to `com.denisefremov.DejaViewPix` (commit `15bd751`). Simulators and devices that had the old build need photo access granted again and the API key re-entered, because Keychain items belong to the app ID. The iPhone 17 simulator (9D3D28C2…) has the seeded photos, photo access and the key.
- Before Day 8 (comparing models): Opus 5.5 and Sonnet 5.5 always think, and their replies contain `thinking` blocks. `ContentBlock` decodes those as `.unknown`, which can't be encoded, so the second request of a tool loop would fail on those models. Keep unknown blocks as raw JSON and send them back unchanged.
