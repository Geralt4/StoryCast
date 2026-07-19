import CryptoKit
import Foundation
import SwiftData

nonisolated struct SyncFileFingerprint: Equatable, Sendable {
    let byteCount: Int64
    let sha256Hex: String
}

nonisolated struct SyncLibraryAuditResult: Equatable, Sendable {
    let importedBookCount: Int
    let verifiedAssetCount: Int
    let missingAssetCount: Int
    let failedAssetCount: Int
}

nonisolated enum SyncFileHasher {
    static func fingerprint(of url: URL) throws -> SyncFileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0

        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return SyncFileFingerprint(byteCount: byteCount, sha256Hex: hex)
    }
}

/// Creates or refreshes local sync sidecars without starting network activity.
/// The audit is repeatable after a crash, file restoration, or a failed import.
@MainActor
enum SyncLibraryAuditor {
    private struct AssetCandidate: Sendable {
        let bookID: UUID
        let kind: SyncAssetKind
        let fileName: String
        let url: URL
    }

    static func audit(
        container: ModelContainer,
        deviceID: String,
        libraryURL: URL = StorageManager.shared.storyCastLibraryURL,
        coverArtDirectoryURL: URL = StorageManager.shared.coverArtDirectoryURL
    ) async -> SyncLibraryAuditResult {
        let context = ModelContext(container)
        let journal = upsertJournal(in: context)
        journal.phaseRaw = "auditing"
        journal.updatedAt = Date()

        do {
            try context.save()
        } catch {
            AppLogger.sync.error("Failed to start local sync audit: \(error.localizedDescription, privacy: .private)")
            return SyncLibraryAuditResult(importedBookCount: 0, verifiedAssetCount: 0, missingAssetCount: 0, failedAssetCount: 1)
        }

        do {
            let books = try context.fetch(FetchDescriptor<Book>()).filter { SyncBookSnapshot(book: $0) != nil }
            let candidates = prepareEntityStates(
                for: books,
                deviceID: deviceID,
                libraryURL: libraryURL,
                coverArtDirectoryURL: coverArtDirectoryURL,
                in: context
            )
            let outcomes = await fingerprint(candidates)
            let counts = apply(outcomes, in: context)

            journal.phaseRaw = counts.failed == 0 ? "complete" : "needsAttention"
            journal.lastProcessedEntityID = nil
            journal.completedAt = counts.failed == 0 ? Date() : nil
            journal.verificationError = counts.failed == 0 ? nil : "Some local assets could not be verified."
            journal.updatedAt = Date()
            try context.save()

            return SyncLibraryAuditResult(
                importedBookCount: books.count,
                verifiedAssetCount: counts.verified,
                missingAssetCount: counts.missing,
                failedAssetCount: counts.failed
            )
        } catch {
            journal.phaseRaw = "needsAttention"
            journal.verificationError = error.localizedDescription
            journal.updatedAt = Date()
            try? context.save()
            AppLogger.sync.error("Local sync audit failed: \(error.localizedDescription, privacy: .private)")
            return SyncLibraryAuditResult(importedBookCount: 0, verifiedAssetCount: 0, missingAssetCount: 0, failedAssetCount: 1)
        }
    }

    private static func prepareEntityStates(
        for books: [Book],
        deviceID: String,
        libraryURL: URL,
        coverArtDirectoryURL: URL,
        in context: ModelContext
    ) -> [AssetCandidate] {
        let entityStates = (try? context.fetch(FetchDescriptor<SyncEntityState>())) ?? []
        var statesByID: [String: SyncEntityState] = [:]
        for state in entityStates where statesByID[state.id] == nil {
            statesByID[state.id] = state
        }
        var candidates: [AssetCandidate] = []
        let folderIDs = Set(books.compactMap { $0.folder?.id })

        for folderID in folderIDs {
            upsertEntityState(
                id: "folder:\(folderID.uuidString.lowercased())",
                kind: .folder,
                localEntityID: folderID.uuidString.lowercased(),
                recordName: SyncRecordName.folder(folderID),
                deviceID: deviceID,
                statesByID: &statesByID,
                in: context
            )
        }

        for book in books {
            let bookID = book.id
            upsertEntityState(
                id: "book:\(bookID.uuidString.lowercased())",
                kind: .book,
                localEntityID: bookID.uuidString.lowercased(),
                recordName: SyncRecordName.book(bookID),
                deviceID: deviceID,
                statesByID: &statesByID,
                in: context
            )

            let chapters = book.chapters.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.title < $1.title
            }
            for (index, _) in chapters.enumerated() {
                upsertEntityState(
                    id: "chapter:\(bookID.uuidString.lowercased()):\(index)",
                    kind: .chapter,
                    localEntityID: "\(bookID.uuidString.lowercased()):\(index)",
                    recordName: SyncRecordName.chapter(bookID: bookID, chapterSetID: bookID, index: index),
                    deviceID: deviceID,
                    statesByID: &statesByID,
                    in: context
                )
            }

            candidates.append(AssetCandidate(
                bookID: bookID,
                kind: .audio,
                fileName: book.localFileName,
                url: libraryURL.appendingPathComponent(book.localFileName)
            ))
            if let coverArtFileName = book.coverArtFileName, !coverArtFileName.isEmpty {
                candidates.append(AssetCandidate(
                    bookID: bookID,
                    kind: .coverArt,
                    fileName: coverArtFileName,
                    url: coverArtDirectoryURL.appendingPathComponent(coverArtFileName)
                ))
            }
        }

        return candidates
    }

    private static func upsertEntityState(
        id: String,
        kind: SyncEntityKind,
        localEntityID: String,
        recordName: String,
        deviceID: String,
        statesByID: inout [String: SyncEntityState],
        in context: ModelContext
    ) {
        if let existing = statesByID[id] {
            existing.recordName = recordName
            return
        }

        let state = SyncEntityState(
            id: id,
            entityKindRaw: kind.rawValue,
            localEntityID: localEntityID,
            recordName: recordName,
            deviceID: deviceID
        )
        statesByID[id] = state
        context.insert(state)
    }

    private static func fingerprint(_ candidates: [AssetCandidate]) async -> [(AssetCandidate, Result<SyncFileFingerprint, Error>)] {
        await withTaskGroup(of: (AssetCandidate, Result<SyncFileFingerprint, Error>).self) { group in
            for candidate in candidates {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: candidate.url.path) else {
                        return (candidate, .failure(CocoaError(.fileNoSuchFile)))
                    }
                    do {
                        return (candidate, .success(try SyncFileHasher.fingerprint(of: candidate.url)))
                    } catch {
                        return (candidate, .failure(error))
                    }
                }
            }

            var results: [(AssetCandidate, Result<SyncFileFingerprint, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private static func apply(
        _ outcomes: [(AssetCandidate, Result<SyncFileFingerprint, Error>)],
        in context: ModelContext
    ) -> (verified: Int, missing: Int, failed: Int) {
        let assets = (try? context.fetch(FetchDescriptor<SyncAsset>())) ?? []
        var assetsByKey: [String: SyncAsset] = [:]
        for asset in assets {
            let key = assetKey(bookID: asset.bookID, kindRaw: asset.kindRaw)
            if assetsByKey[key] == nil {
                assetsByKey[key] = asset
            }
        }
        var verified = 0
        var missing = 0
        var failed = 0

        for (candidate, outcome) in outcomes {
            let key = assetKey(bookID: candidate.bookID, kindRaw: candidate.kind.rawValue)
            let asset = assetsByKey[key] ?? {
                let asset = SyncAsset(
                    bookID: candidate.bookID,
                    kindRaw: candidate.kind.rawValue,
                    originalFileName: candidate.fileName,
                    pathExtension: (candidate.fileName as NSString).pathExtension,
                    contentTypeIdentifier: "public.data",
                    byteCount: 0,
                    sha256Hex: ""
                )
                assetsByKey[key] = asset
                context.insert(asset)
                return asset
            }()

            asset.originalFileName = candidate.fileName
            asset.pathExtension = (candidate.fileName as NSString).pathExtension
            asset.localRelativePath = candidate.fileName

            switch outcome {
            case .success(let fingerprint):
                if !asset.sha256Hex.isEmpty, asset.sha256Hex != fingerprint.sha256Hex {
                    asset.contentRevision += 1
                    asset.cloudStateRaw = SyncAssetCloudState.notScheduled.rawValue
                }
                asset.byteCount = fingerprint.byteCount
                asset.sha256Hex = fingerprint.sha256Hex
                asset.localStateRaw = SyncAssetLocalState.verified.rawValue
                asset.lastVerifiedAt = Date()
                asset.lastErrorMessage = nil
                verified += 1
            case .failure(let error as CocoaError) where error.code == .fileNoSuchFile:
                asset.localStateRaw = SyncAssetLocalState.missing.rawValue
                asset.lastErrorMessage = "Local file is missing."
                missing += 1
            case .failure(let error):
                asset.localStateRaw = SyncAssetLocalState.blocked.rawValue
                asset.lastErrorMessage = error.localizedDescription
                failed += 1
            }
        }

        return (verified, missing, failed)
    }

    private static func assetKey(bookID: UUID, kindRaw: String) -> String {
        "\(bookID.uuidString.lowercased()):\(kindRaw)"
    }

    private static func upsertJournal(in context: ModelContext) -> SyncMigrationJournal {
        var descriptor = FetchDescriptor<SyncMigrationJournal>(predicate: #Predicate { $0.id == "initialLibraryAudit" })
        descriptor.fetchLimit = 1
        if let journal = try? context.fetch(descriptor).first {
            return journal
        }
        let journal = SyncMigrationJournal()
        context.insert(journal)
        return journal
    }
}
