# DejaViewPix

An iOS app built with SwiftUI.

## Project layout

- `DejaViewPix/`: the SwiftUI app.
- `AlbumAI/`: a local Swift package with the core logic: the Claude Messages API client, its request and response types, and Keychain storage for the API key.

## Setup

1. Open `DejaViewPix.xcodeproj` in Xcode.
2. Build and run. Requires iOS 17.5 or later.
3. In the app, paste your Claude API key into the key field and tap **Save**. The key is stored in the Keychain on that device only; it is never written to source code, `Info.plist` or build settings.

## Tests

The package tests run on your Mac, without the simulator:

```
cd AlbumAI
swift test
```

> **Note:** Storing the key in the Keychain is fine for development. A public release should route requests through a backend that holds the key, so it never reaches devices.
