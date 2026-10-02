# DejaViewPix

Natural-language photo search for iOS, built on Claude tool calling. It's a 10-day build following `~/Downloads/Deja_View_Pix_10-Day_Build_Guide.docx` (read it with `textutil -convert txt -stdout <path>`). Each day has a goal, steps, pitfalls and a "done when" check.

**At the start of a session, read `PROGRESS.md`** to see what's done and what comes next. At the end of a day or session, update it.

## Layout

- `DejaViewPix/`: the SwiftUI app (iOS 17.5+). The target defaults to `MainActor` isolation and Swift 5 language mode. The folder is a synchronized group, so any file put in it joins the app target, and non-code files are copied into the app bundle.
- `AlbumAI/`: a local Swift package (Swift 6 mode, iOS 17+ / macOS 14+) with all the core logic: the Messages API types, `ClaudeClient` (an actor), `ClaudeError` and `APIKeyStore` (Keychain). Networking stays out of the views.

## Commands

- Package tests (no simulator): `cd AlbumAI && swift test`
- App build: `xcodebuild -project DejaViewPix.xcodeproj -scheme DejaViewPix -destination 'generic/platform=iOS Simulator' build`

## Rules

- The API key lives only in the Keychain (`APIKeyStore.claude`). Never put it in source code, `Info.plist`, xcconfig files, build settings or scheme environment variables. Never commit it.
- The client reads the key on every request through an injected closure. Don't store it in a property.
- No Anthropic SDK; there's no official one for Swift. Call the HTTP API directly with `anthropic-version: 2023-06-01`.
- Commit and push only when the user asks.
- The repo name stays `DejaViewPix` (the guide says `deja-view-pix`; that's intentional).
