# DejaViewPix

An iOS app built with SwiftUI.

## Setup

1. Open `DejaViewPix.xcodeproj` in Xcode.
2. Configure your API key: take `DejaViewPix/Secrets.example.xcconfig`, copy to `Secrets.xcconfig` and add your key.

   ```
   cp DejaViewPix/Secrets.example.xcconfig DejaViewPix/Secrets.xcconfig
   ```

   Then set `CLAUDE_API_KEY` in `DejaViewPix/Secrets.xcconfig`. This file is ignored by git, so your key stays local.
3. Build and run.
