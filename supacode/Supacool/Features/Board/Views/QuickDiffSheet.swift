import ComposableArchitecture
import SwiftUI

/// In-house "what did I change?" dialog for a worktree. Left column:
/// changed files (from `git status --porcelain`). Right pane: the diff
/// for the selected file (from `git diff HEAD -- <path>`). Read-only —
/// no staging or committing from here.
struct QuickDiffSheet: View {
  let worktreeURL: URL
  let onDismiss: () -> Void

  @State private var files: [ChangedFile] = []
  @State private var selectedPath: String?
  @State private var diffText: String = ""
  @State private var isLoadingFiles: Bool = false
  @State private var isLoadingDiff: Bool = false
  @State private var errorMessage: String?
  @State private var refreshTrigger: Int = 0

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 860, minHeight: 560)
    .task(id: refreshTrigger) { await loadFiles() }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus.forwardslash.minus")
        .foregroundStyle(.secondary)
      Text("Quick diff")
        .font(.headline)
      Text(worktreeURL.lastPathComponent)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      Button {
        refreshTrigger &+= 1
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isLoadingFiles)
      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
    .padding(14)
  }

  @ViewBuilder
  private var content: some View {
    if let errorMessage {
      errorState(errorMessage)
    } else if isLoadingFiles && files.isEmpty {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if files.isEmpty {
      emptyState
    } else {
      HStack(spacing: 0) {
        fileList
          .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
        Divider()
        diffPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - File list

  private var fileList: some View {
    List(selection: Binding(
      get: { selectedPath },
      set: { newValue in
        if let newValue { selectedPath = newValue }
      }
    )) {
      ForEach(files) { file in
        FileRow(file: file)
          .tag(file.path)
      }
    }
    .listStyle(.sidebar)
  }

  // MARK: - Diff pane

  @ViewBuilder
  private var diffPane: some View {
    if let selectedPath, let file = files.first(where: { $0.path == selectedPath }) {
      VStack(spacing: 0) {
        diffPaneHeader(file: file)
        Divider()
        if isLoadingDiff {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if file.status == .untracked {
          untrackedPlaceholder
        } else if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("No textual diff (binary file, or identical to HEAD).")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          diffScrollView
        }
      }
      .task(id: diffTaskID) { await loadDiff(for: file) }
    } else {
      Text("Select a file to view its diff.")
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Re-runs the diff load when either the selection or the user-
  /// requested refresh bumps.
  private var diffTaskID: String {
    "\(selectedPath ?? "")#\(refreshTrigger)"
  }

  private func diffPaneHeader(file: ChangedFile) -> some View {
    HStack(spacing: 8) {
      Image(systemName: file.status.systemImage)
        .foregroundStyle(.secondary)
      Text(file.path)
        .font(.callout.monospaced())
        .textSelection(.enabled)
      Spacer()
      if let added = file.linesAdded, let removed = file.linesRemoved {
        Text("+\(added)")
          .foregroundStyle(.green)
          .font(.caption.monospaced())
        Text("−\(removed)")
          .foregroundStyle(.red)
          .font(.caption.monospaced())
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var untrackedPlaceholder: some View {
    VStack(spacing: 6) {
      Image(systemName: "questionmark.diamond")
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
      Text("Untracked file")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Git doesn't have a previous version to diff against.")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var diffScrollView: some View {
    ScrollView([.vertical, .horizontal]) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(diffText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
          let str = String(line)
          DiffLineView(line: str)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .textSelection(.enabled)
  }

  // MARK: - States

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 42))
        .foregroundStyle(.tertiary)
      Text("Working tree clean")
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
      Text("No uncommitted changes in this worktree.")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.orange)
      Text("Couldn't load diff")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
      Button("Retry") { refreshTrigger &+= 1 }
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Loading

  private func loadFiles() async {
    isLoadingFiles = true
    errorMessage = nil
    defer { isLoadingFiles = false }
    do {
      let output = try await gitClient.statusPorcelain(worktreeURL)
      let parsed = PorcelainStatusParser.parse(output)
      // Enrich with numstat (fire-and-forget per file, collected in
      // parallel). Untracked files get skipped — numstat has nothing
      // to say there.
      let enriched = await withTaskGroup(of: ChangedFile.self) { group -> [ChangedFile] in
        for file in parsed {
          group.addTask { [gitClient, worktreeURL] in
            guard file.status != .untracked else { return file }
            guard let stats = await gitClient.numstatForFile(worktreeURL, file.path) else {
              return file
            }
            var copy = file
            copy.linesAdded = stats.added
            copy.linesRemoved = stats.removed
            return copy
          }
        }
        var out: [ChangedFile] = []
        for await result in group { out.append(result) }
        // Preserve the original `git status` ordering.
        let order = Dictionary(uniqueKeysWithValues: parsed.enumerated().map { ($1.path, $0) })
        out.sort { (order[$0.path] ?? 0) < (order[$1.path] ?? 0) }
        return out
      }
      files = enriched
      if selectedPath == nil || files.first(where: { $0.path == selectedPath }) == nil {
        selectedPath = files.first?.path
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func loadDiff(for file: ChangedFile) async {
    guard file.status != .untracked else {
      diffText = ""
      return
    }
    isLoadingDiff = true
    defer { isLoadingDiff = false }
    do {
      // `cached` is false here — `git diff <path>` covers unstaged
      // changes; combined with `git diff --cached` we'd need two
      // calls. v1 shows working-tree vs. index (what most users
      // want); staged-only review is a future enhancement.
      diffText = try await gitClient.diffForFile(worktreeURL, file.path, false)
    } catch {
      diffText = ""
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - File row

private struct FileRow: View {
  let file: ChangedFile

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: file.status.systemImage)
        .foregroundStyle(iconColor)
        .font(.body)
      VStack(alignment: .leading, spacing: 1) {
        Text(fileName)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
        if !parentDir.isEmpty {
          Text(parentDir)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      if let added = file.linesAdded, added > 0 {
        Text("+\(added)")
          .font(.caption2.monospaced())
          .foregroundStyle(.green)
      }
      if let removed = file.linesRemoved, removed > 0 {
        Text("−\(removed)")
          .font(.caption2.monospaced())
          .foregroundStyle(.red)
      }
    }
    .contentShape(Rectangle())
  }

  private var fileName: String {
    (file.path as NSString).lastPathComponent
  }

  private var parentDir: String {
    let parent = (file.path as NSString).deletingLastPathComponent
    return parent
  }

  private var iconColor: Color {
    switch file.status {
    case .added, .untracked: .green
    case .modified, .typeChanged: .orange
    case .deleted: .red
    case .renamed, .copied: .blue
    case .unknown: .secondary
    }
  }
}

// MARK: - Per-line diff rendering

private struct DiffLineView: View {
  let line: String

  var body: some View {
    Text(line.isEmpty ? " " : line)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 0.5)
  }

  private var color: Color {
    if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
    if line.hasPrefix("+") { return .green }
    if line.hasPrefix("-") { return .red }
    if line.hasPrefix("@@") { return .blue }
    if line.hasPrefix("diff --git") || line.hasPrefix("index ") { return .secondary }
    return .primary
  }
}
