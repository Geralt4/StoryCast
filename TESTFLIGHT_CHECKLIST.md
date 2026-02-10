# TestFlight Pre-Submission Checklist

This checklist ensures all requirements are met before submitting the StoryCast app to TestFlight/App Store Connect.

---

## App Store Connect Metadata

### Application Details

- [ ] App Name: `StoryCast`
- [ ] Subtitle: Brief description (max 30 characters)
- [ ] Primary Category: Books
- [ ] Secondary Category: Entertainment

### Localization (if applicable)

- [ ] English (U.S.)
- [ ] Additional languages as needed

### App Description

Recommended description (adjust as needed):

```
StoryCast is your dedicated audiobook listening companion, designed with performance and ease of use in mind.

KEY FEATURES:
• Import audiobooks from Files app, cloud services, or share sheets
• Automatic chapter detection and navigation
• Customizable playback speed (0.5x to 3.0x)
• Skip forward/backward controls with configurable intervals
• Sleep timer for bedtime listening
• Organize audiobooks into folders
• Cover art display with optimized caching
• Background playback continues while you use other apps
• Progress tracking with resume support

Performance optimized for iOS 17+ with modern Swift concurrency.

Import your audiobooks and enjoy seamless playback with a beautiful, intuitive interface.
```

- [ ] Description written and reviewed
- [ ] Character limits verified (max 4000 characters)
- [ ] No false claims or unsupported features mentioned
- [ ] Keywords researched and optimized

### Privacy Policy

- [ ] Privacy Policy URL provided
- [ ] Privacy policy document created/updated
- [ ] Privacy policy accurately describes data collection:
  - No user account creation
  - No data collected from users
  - All data stored locally on device
  - No analytics or tracking
  - No third-party data sharing

### Support URL

- [ ] Support URL provided (can be simple website or email link)
- [ ] Support contact information verified
- [ ] Response process defined

### App Review Information

- [ ] App Review contact (name, phone, email) provided
- [ ] Review notes entered (anything reviewers should know)
- [ ] Demo account credentials provided (if required)
- [ ] Sign-in requirements explained (if applicable)
- [ ] Backend access instructions included (if applicable)

### App Privacy (Nutrition Label)

- [ ] Data collection declared in App Privacy section
- [ ] Data types and purposes reviewed against actual behavior
- [ ] Tracking set to "No" unless third-party tracking is present
- [ ] SDKs reviewed for data collection or tracking
- [ ] Privacy policy URL matches App Privacy answers

### Tracking Transparency (ATT)

- [ ] ATT prompt not used (confirm no IDFA/ads tracking)
- [ ] If tracking exists, ATT permission text configured and tested
- [ ] IDFA usage confirmed (if used)

### Additional Information

- [ ] Copyright string correct (e.g., "2026 [Developer Name]")
- [ ] Trade Representative contact (if applicable)
- [ ] App SKU defined (unique identifier, e.g., `audiobook-player-1.0`)
- [ ] Developer website URL provided (if required)
- [ ] EULA/Terms of Service URL provided (if required)

---

## App Icon

### Assets.xcassets Verification

Location: `StoryCast/Assets.xcassets/AppIcon.appiconset/Contents.json`

Current configuration:
```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### Checklist

- [x] 1024x1024 universal icon present - iOS uses adaptive icons; 1024x1024 is the required base size
- [x] Dark mode variant present - Icon renders correctly in dark appearance
- [x] Tinted variant present - Icon renders correctly with color tints
- [x] AppIcon.appiconset Contents.json validated - JSON syntax correct
- [x] Actual icon image files exist - Verify .png files are present in the AppIcon.appiconset folder
- [ ] Icon meets design guidelines - No transparency, appropriate padding, legible at small sizes
- [ ] No alpha channel - Icons should not have transparency (iOS adds masking)

### Icon File Requirements

| Size | Scale | Filename Pattern | Required |
|------|-------|------------------|----------|
| 1024x1024 | @1x, @2x, @3x | `icon-name.png` | Yes (1024x1024 @1x) |

To verify icon files exist:
```bash
ls -la StoryCast/Assets.xcassets/AppIcon.appiconset/
```

Expected: `Contents.json` and PNG image files for the 1024x1024 icon sizes.

---

## Versioning

### Current Version Information

Xcode project: `StoryCast.xcodeproj`

Required version fields:

| Field | Location | Current Value | New Value |
|-------|----------|---------------|-----------|
| Marketing Version (CFBundleShortVersionString) | Info.plist / Target settings | 1.0 | [INCREMENT] |
| Build Number (CFBundleVersion) | Info.plist / Target settings | 1 | [INCREMENT] |

### Versioning Rules

Marketing version (CFBundleShortVersionString):
- Use semantic versioning: `MAJOR.MINOR.PATCH`
- Increment MAJOR for breaking changes
- Increment MINOR for new features (backward-compatible)
- Increment PATCH for bug fixes

Build number (CFBundleVersion):
- Must be monotonically increasing (always higher than previous build)
- Common pattern: Use date-based (`2026012701`) or sequential (`1`, `2`, `3`)
- Must be a string of period-separated integers

### Version Update Steps

1. Open Xcode project:
   ```bash
   open StoryCast.xcodeproj
   ```

2. Select project in navigator → Select target → General tab

3. Update version numbers:
   - Version: `1.0.0` (or next appropriate version)
   - Build: `1` (or next sequential number)

4. Alternatively, edit directly in Info.plist:
   ```xml
   <key>CFBundleShortVersionString</key>
   <string>1.0.0</string>
   <key>CFBundleVersion</key>
   <string>1</string>
   ```

### Versioning Checklist

- [ ] Marketing version (CFBundleShortVersionString) incremented
- [ ] Build number (CFBundleVersion) incremented
- [ ] Version numbers verified in Xcode target settings
- [ ] Version numbers verified in Info.plist
- [ ] Build number is higher than any previously submitted build
- [ ] Version format validated (no special characters)
- [ ] TestFlight build number unique across all builds

---

## Export Compliance Information

### Encryption Declaration

Apple requires disclosure of encryption usage in your app, even for App Store distribution.

For StoryCast:

Since the app uses:
- No encryption for data at rest (audiobooks stored in plaintext)
- No encryption for network communications (unless using HTTPS for web-based imports)
- No proprietary encryption algorithms
- Standard iOS system APIs only (no custom cryptographic implementations)

Declaration: The app does NOT use encryption.

### Steps to Declare

1. When uploading to App Store Connect:
   - Answer "No" to encryption questions
   - Or use the export compliance workflow in Xcode

2. In App Store Connect:
   - Navigate to app → App Information
   - Under "Export Compliance," select "No"
   - Provide brief justification if prompted

### Export Compliance Checklist

- [ ] Encryption usage assessed and documented
- [ ] Correct export compliance classification selected
- [ ] If using HTTPS (standard web traffic), no additional declaration needed
- [ ] If app stored encrypted data, proper documentation prepared
- [ ] Annual encryption summary updated (if applicable)

### Common Encryption Triggers

| Feature | Requires Declaration? |
|---------|----------------------|
| HTTPS requests (App Transport Security) | No |
| Local file storage (unencrypted) | No |
| Keychain for secure storage | Yes (but handled by system) |
| Custom encryption algorithms | Yes |
| DRM-protected content handling | Yes |

---

## Additional Pre-Submission Checklist

### Build Validation

- [ ] Build succeeded without errors
- [ ] No warnings in build output
- [ ] Archive build completed successfully
- [ ] All tests pass (if applicable)
- [ ] UI tests pass (if applicable)

### App Store Connect Upload

- [ ] App Store Connect app record created
- [ ] All required metadata fields completed
- [ ] App icon uploaded (if different from asset catalog)
- [ ] Screenshots prepared for all device sizes:
  - 6.7" (iPhone 15 Pro Max, etc.)
  - 6.5" (iPhone 14 Plus, etc.)
  - 6.1" (iPhone 15 Pro, etc.)
  - 5.5" (iPhone 8 Plus, legacy if required)
  - 12.9" iPad Pro (if applicable)
  - 11" iPad Pro (if applicable)
- [ ] App Preview videos prepared (optional)
- [ ] Promotional text added (optional)
- [ ] Keywords field finalized
- [ ] Beta App Description added for TestFlight
- [ ] "What to Test" field added for TestFlight

### Legal & Compliance

- [ ] Terms of Service reviewed
- [ ] Age rating questionnaire completed accurately
- [ ] No trademarked names or copyrighted content in metadata
- [ ] Third-party library licenses acknowledged
- [ ] Content ownership/rights confirmed for sample audiobooks

### Testing

- [ ] TestFlight build tested on physical device
- [ ] All critical user flows verified
- [ ] Performance meets acceptable thresholds
- [ ] No crashes during testing
- [ ] Accessibility features tested

### TestFlight Beta Distribution

- [ ] Internal testers assigned and notified
- [ ] External beta review submitted (if external testing)
- [ ] Public TestFlight link created (if using public link)
- [ ] Build expiration date noted (90 days)
- [ ] Feedback channel communicated to testers

### Build Signing & Capabilities

- [ ] Distribution certificate and profile are valid
- [ ] App capabilities reviewed (background audio, file access)
- [ ] Minimum iOS version matches target (iOS 17+)
- [ ] Supported device families confirmed (iPhone/iPad)
- [ ] Background modes tested (if enabled)

---

## Submission Process

### 1. Prepare Archive
```bash
# In Xcode:
# Product → Archive
```

### 2. Validate and Distribute
- Organizer → Distribute App
- App Store Connect distribution method
- Validate before uploading

### 3. Upload and Submit
- Xcode uploads build to App Store Connect
- Build appears in App Store Connect after processing (5-30 minutes)
- Submit for review in App Store Connect

### 4. Post-Submission
- Monitor App Store Connect for review status
- Prepare response for any review questions
- TestFlight external testers notified (if enabled)
