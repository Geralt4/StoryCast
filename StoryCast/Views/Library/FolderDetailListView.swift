import SwiftUI

struct FolderDetailListView: View {
    let folderBooks: [Book]
    let isEditing: Bool
    @Binding var selectedBookIds: Set<UUID>
    let onDeleteBooks: (IndexSet) -> Void
    let onSelect: (Book) -> Void
    let onMove: (Book) -> Void
    let onDelete: (Book) -> Void
    let emptyStateTitle: String
    let emptyStateDescription: String

    var body: some View {
        List {
            if folderBooks.isEmpty {
                ContentUnavailableView {
                    Label(emptyStateTitle, systemImage: "books.vertical")
                } description: {
                    Text(emptyStateDescription)
                }
            } else {
                ForEach(folderBooks) { book in
                    BookRowView(
                        book: book,
                        isEditing: isEditing,
                        isSelected: selectedBookIds.contains(book.id),
                        onSelect: { onSelect(book) },
                        onMove: { onMove(book) },
                        onDelete: { onDelete(book) }
                    )
                }
                .onDelete(perform: isEditing ? nil : onDeleteBooks)
            }
        }
    }
}
