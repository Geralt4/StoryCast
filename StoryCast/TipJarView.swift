import SwiftUI
import StoreKit
import os

struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tipJarManager = TipJarManager()

    var body: some View {
        Form {
            Section {
                if tipJarManager.products.isEmpty {
                    if tipJarManager.errorMessage != nil {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text("Could not load tip options")
                                .font(.headline)
                            Button("Try Again") {
                                Task {
                                    await tipJarManager.loadProducts()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        HStack {
                            ProgressView()
                            Text("Loading tip options...")
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    ForEach(sortedProducts, id: \.id) { product in
                        TipButton(product: product, tipJarManager: tipJarManager)
                    }
                }
            } header: {
                Text("Choose an amount")
            } footer: {
                VStack(spacing: 8) {
                    Text("Your support helps keep this app free and improving. Thank you!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let errorMessage = tipJarManager.errorMessage, tipJarManager.products.isEmpty == false {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Support Developer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await tipJarManager.loadProducts()
        }
        .alert("Thank you!", isPresented: $tipJarManager.purchaseSuccess) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Your support means a lot to me. Thank you!")
        }
    }

    private var sortedProducts: [Product] {
        let ordering = ["tip_small", "tip_medium", "tip_large"]
        return tipJarManager.products.sorted { a, b in
            guard let indexA = ordering.firstIndex(of: a.id),
                  let indexB = ordering.firstIndex(of: b.id) else {
                return a.id < b.id
            }
            return indexA < indexB
        }
    }
}

struct TipButton: View {
    let product: Product
    @ObservedObject var tipJarManager: TipJarManager

    var body: some View {
        Button(action: {
            Task {
                do {
                    try await tipJarManager.purchase(product)
                } catch {
                    // Error is already displayed via tipJarManager.errorMessage
                    AppLogger.storeKit.debug("Purchase failed for \(product.id): \(error.localizedDescription)")
                }
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tipJarManager.tipDescription(for: product))
                        .font(.headline)
                    Text("Tip \(tipJarManager.tipAmount(for: product))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if tipJarManager.isPurchasing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tipJarManager.isPurchasing)
        .opacity(tipJarManager.isPurchasing ? 0.6 : 1.0)
    }
}

#Preview {
    TipJarView()
}
