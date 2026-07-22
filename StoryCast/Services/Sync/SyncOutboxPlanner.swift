import Foundation
import SwiftData

nonisolated struct SyncOutboxPlanResult: Equatable, Sendable {
    let bookCount: Int
    let operationCount: Int
}

/// Converts the verified local-library sidecars into a durable, dependency-
/// ordered outbox. Planning is idempotent: already published assets and entity
/// revisions are not queued again.
@MainActor
enum SyncOutboxPlanner {
    static func plan(container: ModelContainer, deviceID: String) throws -> SyncOutboxPlanResult {
        let context = ModelContext(container)
        let runtime = try SyncRuntimeStore.runtime(in: context)
        let allOperations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        let allStates = try context.fetch(FetchDescriptor<SyncEntityState>())
        let allAssets = try context.fetch(FetchDescriptor<SyncAsset>())
        let allFolders = try context.fetch(FetchDescriptor<Folder>())
        let allBooks = try context.fetch(FetchDescriptor<Book>())
        let allProgressHeads = try context.fetch(FetchDescriptor<SyncProgressHead>())
        let uploadMarkers = try context.fetch(FetchDescriptor<SyncReplicaUploadMarker>())
        let markedStateIDs = Set(uploadMarkers.map(\.id))

        var operationsBySubject = Dictionary(grouping: allOperations, by: \.subjectID)
        var statesByID = Dictionary(uniqueKeysWithValues: allStates.map { ($0.id, $0) })
        let assetsByBook = Dictionary(grouping: allAssets, by: \.bookID)
        let books = allBooks.compactMap { book -> (Book, SyncBookSnapshot)? in
            SyncBookSnapshot(book: book).map { (book, $0) }
        }
        let eligibleBookIDs = Set(books.map { $0.0.id })

        // Reuse the existing generationID if we have one. Generating a new
        // UUID on every plan() would cause the generation record to be
        // re-uploaded indefinitely, wasting CloudKit quota and triggering
        // unnecessary inbox re-applies on every other device.
        let generationID: UUID
        if let existing = runtime.generationID, let parsed = UUID(uuidString: existing) {
            generationID = parsed
        } else {
            generationID = UUID()
            runtime.generationID = generationID.uuidString.lowercased()
        }
        let generationRecordName = SyncRecordName.generation()
        var createdOperations: [SyncOutboxOperation] = []

        let generationOperation = try ensureOperation(
            kind: .saveRecord,
            subjectKind: .generation,
            subjectID: generationRecordName,
            payload: CloudSyncGenerationPayload(
                generationID: generationID,
                schemaVersion: CloudSyncRecordCodec.schemaVersion,
                createdAt: runtime.updatedAt
            ),
            dependencies: [],
            operationsBySubject: &operationsBySubject,
            createdOperations: &createdOperations,
            in: context
        )
        let generationDependencies = dependencyIfPending(generationOperation)

        var folderOperations: [UUID: SyncOutboxOperation] = [:]
        for folder in allFolders where !folder.isSystem {
            let folderID = folder.id
            let stateID = "folder:\(folderID.uuidString.lowercased())"
            let state = statesByID[stateID] ?? makeState(
                id: stateID,
                kind: .folder,
                localEntityID: folderID.uuidString.lowercased(),
                recordName: SyncRecordName.folder(folderID),
                deviceID: deviceID,
                statesByID: &statesByID,
                in: context
            )
            let contentDigest = try SyncContentDigest.folder(
                id: folder.id,
                name: folder.name,
                sortOrder: folder.sortOrder
            )
            let contentChanged = state.contentDigest != contentDigest
            let forcedUpload = markedStateIDs.contains(stateID)
            let hasPending = hasPendingOperation(for: state.recordName, in: operationsBySubject)
            guard contentChanged || hasPending || forcedUpload else { continue }
            if contentChanged {
                state.revision = max(1, state.revision + 1)
                state.modifiedAt = Date()
                state.deviceID = deviceID
                state.contentDigest = contentDigest
            }

            let operation = try ensureOperation(
                kind: .saveRecord,
                subjectKind: .folder,
                subjectID: state.recordName,
                payload: CloudSyncFolderPayload(
                    folderID: folder.id,
                    name: folder.name,
                    isSystem: false,
                    sortOrder: folder.sortOrder,
                    revision: state.revision,
                    modifiedAt: state.modifiedAt,
                    deviceID: deviceID
                ),
                dependencies: generationDependencies,
                replaceSent: contentChanged || forcedUpload,
                operationsBySubject: &operationsBySubject,
                createdOperations: &createdOperations,
                in: context
            )
            folderOperations[folderID] = operation
        }

        var assetOperations: [UUID: SyncOutboxOperation] = [:]
        var bookOperations: [UUID: SyncOutboxOperation] = [:]
        for asset in allAssets where
            eligibleBookIDs.contains(asset.bookID) &&
            asset.localStateRaw == SyncAssetLocalState.verified.rawValue {
            let recordName = SyncRecordName.asset(asset.id, revision: asset.contentRevision)
            guard asset.cloudStateRaw != SyncAssetCloudState.published.rawValue || hasPendingOperation(for: recordName, in: operationsBySubject) else {
                continue
            }
            let operation = try ensureOperation(
                kind: .uploadAsset,
                subjectKind: .asset,
                subjectID: recordName,
                payload: CloudSyncAssetPayload(
                    assetID: asset.id,
                    bookID: asset.bookID,
                    kind: SyncAssetKind(rawValue: asset.kindRaw) ?? .audio,
                    contentRevision: asset.contentRevision,
                    originalFileName: asset.originalFileName,
                    cloudRelativePath: cloudRelativePath(for: asset),
                    pathExtension: asset.pathExtension,
                    contentTypeIdentifier: asset.contentTypeIdentifier,
                    byteCount: asset.byteCount,
                    sha256Hex: asset.sha256Hex,
                    readyAt: asset.lastVerifiedAt ?? Date(),
                    deviceID: deviceID
                ),
                dependencies: generationDependencies,
                operationsBySubject: &operationsBySubject,
                createdOperations: &createdOperations,
                in: context
            )
            asset.cloudStateRaw = SyncAssetCloudState.queuedForUpload.rawValue
            assetOperations[asset.id] = operation
        }

        for (book, snapshot) in books {
            let bookAssets = assetsByBook[book.id] ?? []
            guard let audio = bookAssets.first(where: {
                $0.kindRaw == SyncAssetKind.audio.rawValue && $0.localStateRaw == SyncAssetLocalState.verified.rawValue
            }) else { continue }
            let cover = bookAssets.first(where: {
                $0.kindRaw == SyncAssetKind.coverArt.rawValue && $0.localStateRaw == SyncAssetLocalState.verified.rawValue
            })
            if snapshot.coverArtFileName != nil, cover == nil { continue }

            let stateID = "book:\(book.id.uuidString.lowercased())"
            let state = statesByID[stateID] ?? makeState(
                id: stateID,
                kind: .book,
                localEntityID: book.id.uuidString.lowercased(),
                recordName: SyncRecordName.book(book.id),
                deviceID: deviceID,
                statesByID: &statesByID,
                in: context
            )

            var dependencies = generationDependencies
            if let folderID = snapshot.folderID, let folderOperation = folderOperations[folderID] {
                dependencies.append(contentsOf: dependencyIfPending(folderOperation))
            }
            if let operation = assetOperations[audio.id] {
                dependencies.append(contentsOf: dependencyIfPending(operation))
            }
            if let cover, let operation = assetOperations[cover.id] {
                dependencies.append(contentsOf: dependencyIfPending(operation))
            }

            let contentDigest = try SyncContentDigest.book(
                id: book.id,
                title: book.title,
                author: book.author,
                duration: book.duration,
                folderID: snapshot.folderID,
                audioAssetID: audio.id,
                audioAssetRevision: audio.contentRevision,
                coverArtAssetID: cover?.id,
                coverArtAssetRevision: cover?.contentRevision,
                chapterSetID: book.id
            )
            let contentChanged = state.contentDigest != contentDigest
            let forcedUpload = markedStateIDs.contains(stateID)
            let hasPending = hasPendingOperation(for: state.recordName, in: operationsBySubject)
            if contentChanged {
                state.revision = max(1, state.revision + 1)
                state.modifiedAt = Date()
                state.deviceID = deviceID
                state.contentDigest = contentDigest
            }

            let bookOperation: SyncOutboxOperation?
            if contentChanged || hasPending || forcedUpload {
                bookOperation = try ensureOperation(
                    kind: .saveRecord,
                    subjectKind: .book,
                    subjectID: state.recordName,
                    payload: CloudSyncBookPayload(
                        bookID: book.id,
                        title: book.title,
                        author: book.author,
                        duration: book.duration,
                        folderID: snapshot.folderID,
                        audioAssetID: audio.id,
                        coverArtAssetID: cover?.id,
                        audioAssetRevision: audio.contentRevision,
                        coverArtAssetRevision: cover?.contentRevision,
                        chapterSetID: book.id,
                        revision: state.revision,
                        modifiedAt: state.modifiedAt,
                        deviceID: deviceID
                    ),
                    dependencies: dependencies,
                    replaceSent: contentChanged || forcedUpload,
                    operationsBySubject: &operationsBySubject,
                    createdOperations: &createdOperations,
                    in: context
                )
            } else {
                bookOperation = nil
            }
            if let bookOperation { bookOperations[book.id] = bookOperation }
            let chapters = book.chapters.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.title < $1.title
            }
            for (index, chapter) in chapters.enumerated() {
                let chapterStateID = "chapter:\(book.id.uuidString.lowercased()):\(index)"
                let chapterState = statesByID[chapterStateID] ?? makeState(
                    id: chapterStateID,
                    kind: .chapter,
                    localEntityID: "\(book.id.uuidString.lowercased()):\(index)",
                    recordName: SyncRecordName.chapter(bookID: book.id, chapterSetID: book.id, index: index),
                    deviceID: deviceID,
                    statesByID: &statesByID,
                    in: context
                )
                let chapterDigest = try SyncContentDigest.chapter(
                    bookID: book.id,
                    chapterSetID: book.id,
                    index: index,
                    title: chapter.title,
                    startTime: chapter.startTime,
                    endTime: chapter.endTime,
                    sourceRaw: chapter.source.rawValue
                )
                let chapterChanged = chapterState.contentDigest != chapterDigest
                let forcedChapterUpload = markedStateIDs.contains(chapterStateID)
                let chapterHasPending = hasPendingOperation(for: chapterState.recordName, in: operationsBySubject)
                guard chapterChanged || chapterHasPending || forcedChapterUpload else { continue }
                if chapterChanged {
                    chapterState.revision = max(1, chapterState.revision + 1)
                    chapterState.modifiedAt = Date()
                    chapterState.deviceID = deviceID
                    chapterState.contentDigest = chapterDigest
                }
                _ = try ensureOperation(
                    kind: .saveRecord,
                    subjectKind: .chapter,
                    subjectID: chapterState.recordName,
                    payload: CloudSyncChapterPayload(
                        bookID: book.id,
                        chapterSetID: book.id,
                        index: index,
                        title: chapter.title,
                        startTime: chapter.startTime,
                        endTime: chapter.endTime,
                        sourceRaw: chapter.source.rawValue,
                        revision: chapterState.revision,
                        modifiedAt: chapterState.modifiedAt,
                        deviceID: deviceID
                    ),
                    dependencies: dependencyIfPending(bookOperation),
                    replaceSent: chapterChanged || forcedChapterUpload,
                    operationsBySubject: &operationsBySubject,
                    createdOperations: &createdOperations,
                    in: context
                )
            }

            let progressRecordName = SyncRecordName.progress(bookID: book.id, deviceID: deviceID)
            if !hasAnyOperation(for: progressRecordName, in: operationsBySubject) {
                let existingHead = allProgressHeads.first(where: { $0.id == progressRecordName })
                let action = SyncProgressAction(
                    bookID: book.id,
                    deviceID: deviceID,
                    actionID: existingHead?.actionID ?? UUID(),
                    position: existingHead?.position ?? book.lastPlaybackPosition,
                    actionAt: existingHead?.actionAt ?? book.lastPlayedDate ?? Date(),
                    sequence: max(1, existingHead?.sequence ?? 0),
                    actionKind: existingHead?.actionKindRaw ?? "checkpoint"
                )
                if existingHead == nil {
                    context.insert(SyncProgressHead(
                        id: progressRecordName,
                        bookID: book.id,
                        deviceID: deviceID,
                        actionID: action.actionID,
                        position: action.position,
                        actionAt: action.actionAt,
                        sequence: action.sequence,
                        actionKindRaw: action.actionKind
                    ))
                }
                _ = try ensureOperation(
                    kind: .saveRecord,
                    subjectKind: .progress,
                    subjectID: progressRecordName,
                    payload: CloudSyncProgressPayload(action: action),
                    dependencies: dependencyIfPending(bookOperation),
                    operationsBySubject: &operationsBySubject,
                    createdOperations: &createdOperations,
                    in: context
                )
            }
        }

        let retentionStates = try context.fetch(FetchDescriptor<SyncAssetRetentionState>())
        var retentionByAsset = Dictionary(uniqueKeysWithValues: retentionStates.map { ($0.assetID, $0) })
        for asset in allAssets where asset.contentRevision > 1 {
            let retention = retentionByAsset[asset.id] ?? {
                let value = SyncAssetRetentionState(assetID: asset.id)
                retentionByAsset[asset.id] = value
                context.insert(value)
                return value
            }()
            guard retention.prunedThroughRevision < asset.contentRevision - 1 else { continue }
            var dependencies = dependencyIfPending(assetOperations[asset.id])
            dependencies.append(contentsOf: dependencyIfPending(bookOperations[asset.bookID]))
            for revision in (retention.prunedThroughRevision + 1)..<asset.contentRevision {
                _ = try ensureOperation(
                    kind: .deleteAsset, subjectKind: .asset,
                    subjectID: SyncRecordName.asset(asset.id, revision: revision),
                    payload: CloudSyncAssetDeletionPayload(assetID: asset.id, revision: revision),
                    dependencies: dependencies, operationsBySubject: &operationsBySubject,
                    createdOperations: &createdOperations, in: context
                )
            }
        }

        runtime.updatedAt = Date()
        try context.save()
        return SyncOutboxPlanResult(bookCount: books.count, operationCount: createdOperations.count)
    }

    private static func ensureOperation<Payload: Encodable>(
        kind: SyncOutboxKind,
        subjectKind: SyncEntityKind,
        subjectID: String,
        payload: Payload,
        dependencies: [UUID],
        replaceSent: Bool = false,
        operationsBySubject: inout [String: [SyncOutboxOperation]],
        createdOperations: inout [SyncOutboxOperation],
        in context: ModelContext
    ) throws -> SyncOutboxOperation {
        if let pending = operationsBySubject[subjectID]?.first(where: {
            $0.kindRaw == kind.rawValue && $0.stateRaw != "sent"
        }) {
            pending.payloadData = try CloudSyncRecordCodec.encodePayload(payload)
            pending.dependencyData = try SyncOutboxDependencyCodec.encode(Array(Set(dependencies)))
            pending.stateRaw = "queued"
            pending.nextRetryAt = nil
            pending.lastErrorMessage = nil
            return pending
        }
        if !replaceSent, let sent = operationsBySubject[subjectID]?.first(where: {
            $0.kindRaw == kind.rawValue && $0.stateRaw == "sent"
        }) {
            return sent
        }
        let operation = try SyncOutboxStore.upsert(
            kind: kind,
            subjectKind: subjectKind,
            subjectID: subjectID,
            payloadData: try CloudSyncRecordCodec.encodePayload(payload),
            dependencyIDs: Array(Set(dependencies)),
            in: context
        )
        operationsBySubject[subjectID, default: []].append(operation)
        createdOperations.append(operation)
        return operation
    }

    private static func makeState(
        id: String,
        kind: SyncEntityKind,
        localEntityID: String,
        recordName: String,
        deviceID: String,
        statesByID: inout [String: SyncEntityState],
        in context: ModelContext
    ) -> SyncEntityState {
        let state = SyncEntityState(
            id: id,
            entityKindRaw: kind.rawValue,
            localEntityID: localEntityID,
            recordName: recordName,
            deviceID: deviceID
        )
        statesByID[id] = state
        context.insert(state)
        return state
    }

    private static func dependencyIfPending(_ operation: SyncOutboxOperation?) -> [UUID] {
        guard let operation, operation.stateRaw != "sent" else { return [] }
        return [operation.id]
    }

    private static func hasPendingOperation(
        for subjectID: String,
        in operationsBySubject: [String: [SyncOutboxOperation]]
    ) -> Bool {
        operationsBySubject[subjectID]?.contains(where: { $0.stateRaw != "sent" }) == true
    }

    private static func hasAnyOperation(
        for subjectID: String,
        in operationsBySubject: [String: [SyncOutboxOperation]]
    ) -> Bool {
        !(operationsBySubject[subjectID] ?? []).isEmpty
    }

    private static func cloudRelativePath(for asset: SyncAsset) -> String {
        let suffix = asset.pathExtension.isEmpty ? "" : ".\(asset.pathExtension.lowercased())"
        return "assets/\(asset.bookID.uuidString.lowercased())/\(asset.id.uuidString.lowercased())-\(asset.contentRevision)\(suffix)"
    }
}
