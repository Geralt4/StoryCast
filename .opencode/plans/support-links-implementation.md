# Implementation Plan: Enhancing Support Tab with Compliance Links

**Status:** Completed
**Date:** April 25, 2026
**Target:** App Store Compliance (Guideline 5.1.1)

## 1. Objective
Ensure the application complies with App Store Review Guideline 5.1.1 by providing direct, accessible links to the Privacy Policy and Support documentation within the application's user interface.

## 2. Technical Changes

### 2.1 Configuration (`StoryCast/Constants.swift`)
Add hosted documentation URLs to the `AppConstants` enumeration to maintain a single source of truth.
- **Added:** `privacyPolicyURL` pointing to `https://geralt4.github.io/StoryCast/privacy.html`.
- **Added:** `supportURL` pointing to `https://geralt4.github.io/StoryCast/support.html`.

### 2.2 User Interface (`StoryCast/SettingsView.swift`)
Integrate dynamic links into the "Support" section of the settings form using SwiftUI `Link` views.
- **Privacy Policy Link:** Added with `shield.fill` icon (Green).
- **Support & FAQ Link:** Added with `questionmark.circle.fill` icon (Blue).
- **Styling:** Included `arrow.up.forward.app` secondary icons to indicate external browser redirection, following iOS system conventions.

## 3. Verification Steps
1. **Compilation:** Verify the project builds without errors (`xcodebuild`).
2. **URL Integrity:** Ensure `AppConstants` references the correct GitHub Pages endpoints.
3. **UI Layout:** Confirm the new links appear appropriately between "Contact Support" and "Support Developer" (Tip Jar).

## 4. Dependencies
- None. Uses native SwiftUI `Link` component and standard `Foundation` types.
