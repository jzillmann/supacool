import SwiftUI

/// Horizontal row of bookmark mini-cards, rendered directly above the
/// "Waiting on Me" section on the Matrix Board. Hidden when the selected
/// repo has no bookmarks — the caller is responsible for not mounting
/// this view when `bookmarks` is empty or the repo filter is "All repos".
struct BookmarkPillRow: View {
  let bookmarks: [Bookmark]
  let onTap: (Bookmark) -> Void
  let onEdit: (Bookmark) -> Void
  let onDelete: (Bookmark) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(bookmarks) { bookmark in
          BookmarkPillView(
            bookmark: bookmark,
            onTap: { onTap(bookmark) },
            onEdit: { onEdit(bookmark) },
            onDelete: { onDelete(bookmark) }
          )
        }
      }
      .padding(.horizontal, 2)
      .padding(.vertical, 2)
    }
  }
}
