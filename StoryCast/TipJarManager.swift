import StoreKit
import Foundation
import Combine
import os

enum TipJarManagerError: LocalizedError {
    case productNotFound
    case purchaseFailed(Error)
    case productNotAvailable

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Tip product not found"
        case .purchaseFailed(let error):
            return "Purchase failed: \(error.localizedDescription)"
        case .productNotAvailable:
            return "Tip products are not currently available"
        }
    }
}

@MainActor
class TipJarManager: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var purchaseSuccess = false
    @Published private(set) var errorMessage: String?

    private let productIds = ["tip_small", "tip_medium", "tip_large"]
    
    private var updateListenerTask: Task<Void, Error>?

    init() {
        updateListenerTask = listenForTransactions()
    }

    deinit {
        updateListenerTask?.cancel()
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: productIds)
        } catch {
            AppLogger.storeKit.error("Failed to load products: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to load tip options"
        }
    }

    func purchase(_ product: Product) async throws {
        guard !isPurchasing else { return }

        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)

                await transaction.finish()
                AppLogger.storeKit.info("Tip purchase successful: \(product.id, privacy: .private(mask: .hash))")
                purchaseSuccess = true

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                purchaseSuccess = false

            case .userCancelled:
                AppLogger.storeKit.info("Tip purchase cancelled by user")
                errorMessage = nil

            case .pending:
                errorMessage = "Purchase is pending"

            @unknown default:
                break
            }
        } catch {
            AppLogger.storeKit.error("Tip purchase failed: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            throw TipJarManagerError.purchaseFailed(error)
        }
    }

    private func listenForTransactions() -> Task<Void, Error>? {
        return Task { @MainActor in
            for await result in Transaction.updates {
                do {
                    let transaction = try checkVerified(result)
                    await transaction.finish()

                    purchaseSuccess = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    purchaseSuccess = false
                } catch {
                    AppLogger.storeKit.error("Transaction verification failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw TipJarManagerError.purchaseFailed(NSError(domain: "TipJarManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transaction verification failed"]))
        }
    }

    func restorePurchases() async {
        isRestoring = true
        errorMessage = nil

        do {
            try await AppStore.sync()
            AppLogger.storeKit.info("Restore purchases completed successfully")
        } catch {
            AppLogger.storeKit.error("Restore purchases failed: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Could not restore purchases. Please try again."
        }

        isRestoring = false
    }

    func tipAmount(for product: Product) -> String {
        return product.displayPrice
    }

    func tipDescription(for product: Product) -> String {
        switch product.id {
        case "tip_small":
            return "Small tip"
        case "tip_medium":
            return "Medium tip"
        case "tip_large":
            return "Large tip"
        default:
            return "Tip"
        }
    }
}
