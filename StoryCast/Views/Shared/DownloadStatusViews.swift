import Combine
import SwiftUI
import UIKit

/// A small ring showing a fraction from 0 to 1.
struct CircularProgressView: View {
    let progress: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// What a remote book's download is doing, for icons, menus and VoiceOver.
nonisolated enum BookDownloadDisplayState: Equatable {
    case streaming
    case downloading(progress: Double)
    case failed(DownloadFailure)
    case downloaded

    @MainActor
    init(book: Book, manager: DownloadManager = .shared) {
        let state = manager.downloads[book.id]
        if let state, state.isActive {
            self = .downloading(progress: state.progress)
        } else if !book.isDownloaded, let failure = state?.failure, failure != .cancelled {
            self = .failed(failure)
        } else if book.isDownloaded {
            self = .downloaded
        } else {
            self = .streaming
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .streaming: return "Remote book"
        case .downloading(let progress): return "Downloading, \(Int((progress * 100).rounded())) percent"
        case .failed: return "Download failed"
        case .downloaded: return "Downloaded for offline"
        }
    }
}

/// The download icon on a remote book's row: a progress ring while
/// downloading, a warning after a failure, otherwise the source icon.
struct BookDownloadIndicator: View {
    let book: Book
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        switch BookDownloadDisplayState(book: book, manager: manager) {
        case .downloading(let progress):
            HStack(spacing: 4) {
                CircularProgressView(progress: progress, lineWidth: 2)
                    .frame(width: 14, height: 14)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BookDownloadDisplayState.downloading(progress: progress).accessibilityDescription)
        case .failed:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityLabel("Download failed")
        case .downloaded:
            Image(systemName: "icloud.and.arrow.down.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .accessibilityLabel("Downloaded for offline")
        case .streaming:
            Image(systemName: "icloud")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityLabel("Remote book")
        }
    }
}

/// Download actions for a remote book's context menu.
struct BookDownloadMenuItems: View {
    let book: Book
    let onDownload: () -> Void
    let onRemoveDownload: () -> Void
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        switch BookDownloadDisplayState(book: book, manager: manager) {
        case .downloading:
            Button(role: .destructive) {
                HapticManager.impact(.light)
                manager.cancelDownload(bookId: book.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .failed:
            Button {
                HapticManager.impact(.light)
                onDownload()
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise.icloud")
            }
            Button(role: .destructive) {
                HapticManager.impact(.light)
                manager.discardPartialDownload(bookId: book.id)
            } label: {
                Label("Discard Partial Download", systemImage: "trash")
            }
        case .downloaded:
            Button {
                HapticManager.impact(.light)
                onRemoveDownload()
            } label: {
                Label("Remove Download", systemImage: "icloud.and.arrow.down")
            }
        case .streaming:
            Button {
                HapticManager.impact(.light)
                onDownload()
            } label: {
                Label("Download for Offline", systemImage: "icloud.and.arrow.down")
            }
        }
    }
}

/// Adds the download state to a row's VoiceOver value, with Cancel and Retry
/// actions. It observes the download manager itself, so an `Equatable` row
/// doesn't have to re-render on every progress update.
struct BookDownloadAccessibility: ViewModifier {
    let book: Book
    let baseValue: String
    let onDownload: () -> Void
    @ObservedObject private var manager = DownloadManager.shared

    func body(content: Content) -> some View {
        let state = book.isRemote ? BookDownloadDisplayState(book: book, manager: manager) : nil
        let value: String = {
            switch state {
            case .downloading, .failed: return [baseValue, state?.accessibilityDescription].compactMap { $0 }.joined(separator: ", ")
            default: return baseValue
            }
        }()
        content
            .accessibilityValue(value)
            .accessibilityAction(named: Text("Cancel download")) {
                if case .downloading = state { manager.cancelDownload(bookId: book.id) }
            }
            .accessibilityAction(named: Text("Retry download")) {
                if case .failed = state { onDownload() }
            }
    }
}

/// Shows failed downloads as alerts, one at a time. Alerts are presented on
/// the top-most view controller, so they appear even while a sheet is open.
@MainActor
final class DownloadFailurePresenter {
    static let shared = DownloadFailurePresenter()

    private var cancellable: AnyCancellable?
    private var presentedNoticeID: UUID?

    private init() {}

    func start() {
        guard cancellable == nil else { return }
        cancellable = DownloadManager.shared.$failureNotices.sink { [weak self] notices in
            // @Published delivers the new value before it is stored.
            Task { @MainActor [weak self] in self?.presentNext(from: notices) }
        }
    }

    private func presentNext(from notices: [DownloadFailureNotice]) {
        guard presentedNoticeID == nil, let notice = notices.first,
              let presenter = Self.topViewController() else { return }
        presentedNoticeID = notice.id
        let alert = UIAlertController(
            title: "Couldn't Download “\(notice.title)”",
            message: notice.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.presentedNoticeID = nil
                DownloadManager.shared.dismissFailureNotice(notice)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

