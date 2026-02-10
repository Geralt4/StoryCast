import SwiftUI

struct ImportProgressOverlay: View {
    @ObservedObject var importService: ImportService
    let onCancel: () -> Void

    private var progressPercent: Int {
        Int((importService.downloadProgress * 100).rounded())
    }

    private var importAccessibilityValue: String {
        if importService.currentPhase == .downloading {
            return "\(progressPercent) percent, file \(importService.completedFiles + 1) of \(max(importService.totalFiles, 1))"
        }
        return "\(importService.completedFiles) of \(max(importService.totalFiles, 1)) files"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(ColorDefaults.overlayOpacity)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: LayoutDefaults.contentPadding) {
                Group {
                    switch importService.currentPhase {
                    case .downloading:
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.largeTitle)
                    case .processing:
                        Image(systemName: "doc.badge.gearshape")
                            .font(.largeTitle)
                    case .idle:
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                .symbolEffect(.pulse)
                .accessibilityHidden(true)

                VStack(spacing: LayoutDefaults.smallSpacing) {
                    Text(importService.currentPhase.rawValue)
                        .font(.headline)

                    if importService.currentPhase == .downloading {
                        ProgressView(value: importService.downloadProgress)
                            .frame(width: LayoutDefaults.progressBarWidth)
                            .accessibilityLabel("Download progress")
                            .accessibilityValue("\(progressPercent) percent")
                        Text("\(Int(importService.downloadProgress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    } else {
                        Text("\(importService.completedFiles) of \(importService.totalFiles)")
                            .font(.subheadline)
                            .monospacedDigit()
                    }

                    if !importService.currentFileName.isEmpty {
                        Text(importService.currentFileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(ColorDefaults.mutedTextOpacity)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(LayoutDefaults.overlayPadding)
            .background(
                RoundedRectangle(cornerRadius: LayoutDefaults.overlayCornerRadius)
                    .fill(Color(.systemBackground).opacity(ColorDefaults.nearSolidOpacity))
                    .shadow(radius: LayoutDefaults.overlayShadowRadius)
            )
            .padding(.horizontal, LayoutDefaults.overlayHorizontalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Import in progress")
            .accessibilityValue(importAccessibilityValue)
            .accessibilityHint("Wait for import to finish or cancel")
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.primary)
                    .padding(LayoutDefaults.smallSpacing)
            }
            .accessibilityLabel("Cancel import")
            .accessibilityHint("Stops current import")
            .padding(.top, LayoutDefaults.contentPadding)
            .padding(.trailing, LayoutDefaults.contentPadding)
        }
    }
}
