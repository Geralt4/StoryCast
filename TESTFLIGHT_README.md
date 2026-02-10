# TestFlight Release Documentation

## What to Test

This TestFlight build focuses on verifying the new performance optimizations implemented throughout the StoryCast app. Testers should focus on the following areas:

### Beta App Description (App Store Connect)

StoryCast is a focused, offline-first audiobook app built for smooth playback and reliable importing. This beta checks performance work around cover art caching, background imports, and SwiftData concurrency. Please stress test large libraries, imports, and playback under load, and report any stutters, crashes, or data loss.

### Caching System Performance

- Cover art loading: Verify that cover art images load quickly and are properly cached in memory. Import multiple audiobooks with different cover art and confirm that subsequent views of the same cover art are instant.
- Cache behavior: Test that the in-memory cache persists correctly during app sessions and that memory usage remains stable even after importing 10+ audiobooks.
- Memory efficiency: Monitor app memory usage during intensive audiobook importing and playback scenarios.

### Background Task Performance

- Import processing: Test importing large audiobook files (500MB+) while the app is in the background. Verify that imports complete successfully and don't get interrupted when switching apps.
- Concurrent operations: Import multiple audiobooks simultaneously and verify that the app handles concurrent processing without crashing or freezing.
- Task priority: Confirm that import operations yield appropriately to playback operations, ensuring smooth audio playback during background imports.

### SwiftData Concurrency

- Model operations: Test all CRUD operations (Create, Read, Update, Delete) on audiobooks and chapters to verify SwiftData integration works correctly with the new actor-based architecture.
- Data persistence: Force-quit the app and restart it to ensure all imported audiobook data persists correctly.
- Relationship handling: Test folder organization features by creating folders and moving audiobooks between them, verifying that relationships are maintained correctly.
- Background contexts: Perform heavy data operations (importing many audiobooks) while simultaneously navigating the library and starting playback.

### Critical User Flows to Test

1. Import to playback flow: Import an audiobook, wait for completion, start playback, and verify chapter navigation works correctly.
2. Multiple concurrent imports: Select 5+ audiobooks from Files, confirm import starts, let them process, and verify all complete successfully.
3. Library navigation under load: Start a large import, navigate between library, folders, and settings, and confirm the UI stays responsive.
4. Playback during import: Start playing an audiobook, begin importing another, and verify audio doesn't stutter or drop frames.
5. App lifecycle: Start import, put app in background, switch to other apps, return to app, and verify import progress continued.

### Performance Benchmarks

- Initial cover art load: < 500ms for typical files
- Import processing time: Should complete within 2x file size in seconds (e.g., 100MB file in < 200 seconds)
- App launch time: < 3 seconds with 50+ audiobooks in library
- UI responsiveness: No dropped frames during library navigation

---

## How to Provide Feedback

- Use TestFlight's "Send Beta Feedback" button and include steps to reproduce
- Attach screenshots or screen recordings when possible
- Include device model, iOS version, and build number in notes
- If a crash occurs, note what you were doing immediately beforehand

---

## Release Notes

### Version 1.x - Performance Optimization Release

StoryCast receives significant performance enhancements focused on caching, background processing, and modern Swift concurrency patterns.

Key improvements:

- Enhanced caching architecture: Implemented actor-based cover art caching system that provides thread-safe, performant image retrieval with intelligent memory management.

- Background task processing: All audiobook import operations now run on detached background tasks with appropriate priority levels, ensuring the main thread remains responsive during heavy processing.

- SwiftData integration: Migrated data persistence to SwiftData with proper actor isolation, providing type-safe, efficient data management while maintaining smooth UI performance.

- Memory optimization: Reduced memory footprint during large audiobook imports through strategic use of Task.detached and careful resource management.

Additional changes:

- Improved chapter extraction reliability for various audiobook formats
- Enhanced error handling for network-based imports
- Better progress tracking during import operations
- Optimized sleep timer and playback settings persistence

Known limitations:

- Very large audiobook files (>1GB) may take extended time to process on older devices
- DRM-protected files from certain providers cannot be imported

Requirements:

- iOS 17.0 or later
- iPhone, iPad
