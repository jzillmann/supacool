import SwiftUI

/// Horizontal row of draft mini-pills, rendered above the bookmark row
/// at the top of the Matrix Board. Hidden entirely when there are no
/// drafts — when present, an "eyebrow" caption labels it so first-time
/// users notice the row exists.
///
/// Drafts cross repos by design (they're inbox state, not project state),
/// so unlike `BookmarkPillRow` this view doesn't honor the repo filter.
struct DraftPillRow: View {
  let drafts: [Draft]
  /// Lookup from `Draft.repositoryID` → short label. Built by the parent
  /// from the live repository list so unregistered repos render with no
  /// label rather than a stale name.
  let repoLabelByID: [String: String]
  let onTap: (Draft) -> Void
  let onDelete: (Draft) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Drafts")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.5)
        .padding(.leading, 4)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(drafts) { draft in
            DraftPillView(
              draft: draft,
              repoLabel: draft.repositoryID.flatMap { repoLabelByID[$0] },
              onTap: { onTap(draft) },
              onDelete: { onDelete(draft) }
            )
          }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
      }
    }
  }
}
