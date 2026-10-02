# DejaViewPix

An iOS app built with SwiftUI.

## Setup

1. Open `DejaViewPix.xcodeproj` in Xcode.
2. Configure your API key: take `DejaViewPix/Secrets.example.xcconfig`, copy to `Secrets.xcconfig` and add your key.

   ```
   cp DejaViewPix/Secrets.example.xcconfig DejaViewPix/Secrets.xcconfig
   ```

   Then set `CLAUDE_API_KEY` in `DejaViewPix/Secrets.xcconfig`. This file is ignored by git, so your key stays local.
3. Build and run. Requires iOS 17.5 or later.

> **Note:** The API key is embedded in the app's `Info.plist` and can be extracted from any built `.ipa`. This is fine for local development, but a public release should route requests through a backend that holds the key.
