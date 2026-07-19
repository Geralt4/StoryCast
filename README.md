# StoryCast

A privacy-focused iOS audiobook player with Audiobookshelf integration.

## Features

- **Local Audiobooks** — Import and organize your audiobook files locally
- **Audiobookshelf Integration** — Connect to your self-hosted Audiobookshelf server to stream and sync your library
- **Folder Organization** — Organize audiobooks into custom folders
- **Optional iCloud Sync** — Keep imported books, cover art, folders, chapters, and playback progress in your private iCloud database
- **Chapter Navigation** — Jump between chapters with ease
- **Playback Controls** — Variable speed playback, sleep timer, and skip intervals
- **Background Playback** — Continue listening while using other apps
- **AirPlay Support** — Stream to AirPlay-compatible devices
- **Privacy First** — No data collection, no accounts required, no analytics

## Tech Stack

- Swift & SwiftUI
- SwiftData for local persistence
- AVFoundation for audio playback

## Privacy

StoryCast respects your privacy. We do not collect or transmit data to StoryCast-operated servers. Your imported library stays on-device unless you explicitly enable iCloud Sync, which stores supported library data in your private iCloud database.

Audiobookshelf data and credentials are never included in iCloud Sync. Connections to your own Audiobookshelf server remain entirely under your control. See our [Privacy Policy](https://geralt4.github.io/StoryCast/privacy.html) for details.

## Requirements

- iOS 17.0 or later

## Links

- [Support & FAQ](https://geralt4.github.io/StoryCast/support.html)
- [Privacy Policy](https://geralt4.github.io/StoryCast/privacy.html)

## License

MIT License
