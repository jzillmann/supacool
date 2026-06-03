import ComposableArchitecture
import SwiftUI

/// In-house "what did I change?" dialog for a worktree. Left column:
/// changed files (from `git status --porcelain`). Right pane: the diff
/// for the selected file (from `git diff HEAD -- <path>`). Untracked rows
/// can be moved to Trash or appended to `.gitignore` from the context menu.
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
  @State private var pendingDeletion: ChangedFile?

  /// Two source options: uncommitted working-tree changes vs. HEAD
  /// (default) or the branch's committed delta vs. its merge base.
  enum DiffMode: Hashable { case workingTree; case branchVsBase }
  @State private var diffMode: DiffMode = .workingTree
  /// Default branch ref (e.g. `origin/main`). `nil` when it can't be
  /// resolved — in which case the `.branchVsBase` segment is disabled.
  @State private var baseRef: String?
  /// Current branch name (or `nil` when detached). Used to disable the
  /// vs-base segment when we're already *on* the base.
  @State private var currentBranch: String?

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 860, minHeight: 560)
    .task { await resolveBranchRefs() }
    .task(id: "\(refreshTrigger)-\(diffMode)") { await loadFiles() }
    .alert(
      item: $pendingDeletion,
      title: { _ in Text("Move untracked file to Trash?") },
      actions: { file in
        Button("Move to Trash", role: .destructive) {
          moveUntrackedFileToTrash(file)
        }
        Button("Cancel", role: .cancel) {}
      },
      message: { file in
        Text("This moves “\(file.path)” to the Trash and refreshes the diff.")
      }
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus.forwardslash.minus")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Quick diff")
        .font(.headline)
      Text(worktreeURL.lastPathComponent)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      modePicker
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

  /// Two-segment source picker. Hidden when a base ref can't be
  /// resolved — presenting a disabled segment we can never enable would
  /// just be noise. On hide we also force diffMode back to
  /// `.workingTree` so a stale selection from a prior session doesn't
  /// leave the sheet fetching against a ref we no longer have.
  @ViewBuilder
  private var modePicker: some View {
    if let base = resolvedBaseRef {
      Picker("Source", selection: $diffMode) {
        Text("Working tree").tag(DiffMode.workingTree)
        Text("vs. \(base)").tag(DiffMode.branchVsBase)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .help("Switch between uncommitted work and the branch's committed delta.")
    } else {
      EmptyView()
    }
  }

  /// The base ref we can actually diff against — nil when the toggle
  /// should be disabled (no remote, detached HEAD, or sitting on base).
  private var resolvedBaseRef: String? {
    guard let baseRef else { return nil }
    // "On the base" check: compare the short branch name against the
    // trailing component of baseRef (`origin/main` → `main`).
    if let currentBranch, baseRef.hasSuffix("/\(currentBranch)") {
      return nil
    }
    return baseRef
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
          .contextMenu {
            fileContextMenu(for: file)
          }
      }
    }
    .listStyle(.sidebar)
  }

  @ViewBuilder
  private func fileContextMenu(for file: ChangedFile) -> some View {
    if diffMode == .workingTree, file.status == .untracked {
      Button {
        addUntrackedFileToGitignore(file)
      } label: {
        Label("Add to .gitignore", systemImage: "hand.raised")
      }
      Button(role: .destructive) {
        pendingDeletion = file
      } label: {
        Label("Move to Trash…", systemImage: "trash")
      }
    } else {
      Button("Actions available for untracked working-tree files") {}
        .disabled(true)
    }
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

  /// Re-runs the diff load when the selection, the user-requested
  /// refresh, or the diff mode changes (so flipping the header toggle
  /// with a file already selected refetches against the right base).
  private var diffTaskID: String {
    "\(selectedPath ?? "")#\(refreshTrigger)#\(diffMode)"
  }

  private func diffPaneHeader(file: ChangedFile) -> some View {
    HStack(spacing: 8) {
      Image(systemName: file.status.systemImage)
        .foregroundStyle(.secondary)
        .accessibilityLabel(file.status.accessibilityLabel)
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
        .accessibilityHidden(true)
      Text("Untracked file")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Git doesn't have a previous version to diff against.")
        .font(.callout)
        .foregroundStyle(.tertiary)
      Text("Right-click the file to move it to Trash or add it to .gitignore.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var diffScrollView: some View {
    ScrollView([.vertical, .horizontal]) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(
          Array(diffText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
          id: \.offset
        ) { _, line in
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
        .accessibilityHidden(true)
      Text(emptyStateTitle)
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
      Text(emptyStateSubtitle)
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateTitle: String {
    switch diffMode {
    case .workingTree: "Working tree clean"
    case .branchVsBase: "Branch matches \(baseRef ?? "base")"
    }
  }

  private var emptyStateSubtitle: String {
    switch diffMode {
    case .workingTree: "No uncommitted changes in this worktree."
    case .branchVsBase: "No commits since diverging from the base branch."
    }
  }

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
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

  // MARK: - File actions

  private func moveUntrackedFileToTrash(_ file: ChangedFile) {
    guard file.status == .untracked, diffMode == .workingTree else { return }
    do {
      let fileURL = try resolvedWorktreeFileURL(for: file.path)
      var trashedURL: NSURL?
      try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
      selectedPath = nil
      errorMessage = nil
      refreshTrigger &+= 1
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addUntrackedFileToGitignore(_ file: ChangedFile) {
    guard file.status == .untracked, diffMode == .workingTree else { return }
    do {
      _ = try resolvedWorktreeFileURL(for: file.path)
      let pattern = GitignorePattern.repoRootAnchoredPattern(for: file.path)
      try appendGitignorePattern(pattern)
      selectedPath = nil
      errorMessage = nil
      refreshTrigger &+= 1
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func resolvedWorktreeFileURL(for path: String) throws -> URL {
    guard !path.hasPrefix("/") else {
      throw QuickDiffFileActionError.absolutePath(path)
    }
    let baseURL = worktreeURL.standardizedFileURL
    let fileURL = baseURL.appending(path: path).standardizedFileURL
    guard isPath(fileURL, inside: baseURL) else {
      throw QuickDiffFileActionError.pathEscapesWorktree(path)
    }
    return fileURL
  }

  private func appendGitignorePattern(_ pattern: String) throws {
    let gitignoreURL = worktreeURL
      .standardizedFileURL
      .appending(path: ".gitignore", directoryHint: .notDirectory)
    let fileManager = FileManager.default
    let gitignorePath = gitignoreURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: gitignorePath) else {
      try "# Added by Supacool Quick Diff\n\(pattern)\n"
        .write(to: gitignoreURL, atomically: true, encoding: .utf8)
      return
    }

    var contents = try String(contentsOf: gitignoreURL, encoding: .utf8)
    let existingPatterns = contents
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard !existingPatterns.contains(pattern) else { return }
    if !contents.isEmpty, !contents.hasSuffix("\n") {
      contents.append("\n")
    }
    contents.append(pattern)
    contents.append("\n")
    try contents.write(to: gitignoreURL, atomically: true, encoding: .utf8)
  }

  private func isPath(_ fileURL: URL, inside baseURL: URL) -> Bool {
    let basePath = baseURL.path(percentEncoded: false)
    let filePath = fileURL.path(percentEncoded: false)
    let normalizedBasePath = basePath.hasSuffix("/") ? basePath : basePath + "/"
    return filePath.hasPrefix(normalizedBasePath)
  }

  // MARK: - Loading

  /// One-shot lookup of the default branch ref + current branch so the
  /// header picker can decide whether "vs. base" is offered at all.
  /// Failures downgrade silently — the picker just hides its second
  /// segment.
  private func resolveBranchRefs() async {
    async let base = (try? await gitClient.defaultRemoteBranchRef(worktreeURL)) ?? nil
    async let branch = await gitClient.branchName(worktreeURL)
    let (resolvedBase, resolvedBranch) = await (base, branch)
    baseRef = resolvedBase
    currentBranch = resolvedBranch
  }

  private func loadFiles() async {
    isLoadingFiles = true
    errorMessage = nil
    defer { isLoadingFiles = false }
    do {
      let fetched: [ChangedFile]
      switch diffMode {
      case .workingTree:
        fetched = try await fetchWorkingTreeFiles()
      case .branchVsBase:
        guard let base = resolvedBaseRef else {
          // Fell through (e.g. rapid toggle while base ref was still
          // resolving). Bail gracefully; the picker will vanish once
          // resolveBranchRefs completes.
          files = []
          selectedPath = nil
          return
        }
        fetched = try await gitClient.changedFilesAgainst(base, worktreeURL)
      }
      files = fetched
      if selectedPath == nil || files.first(where: { $0.path == selectedPath }) == nil {
        selectedPath = files.first?.path
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Working-tree file listing: porcelain status + parallel per-file
  /// numstat enrichment (untracked skipped — numstat has nothing for
  /// them). Extracted so `loadFiles` stays readable.
  private func fetchWorkingTreeFiles() async throws -> [ChangedFile] {
    let output = try await gitClient.statusPorcelain(worktreeURL)
    let parsed = PorcelainStatusParser.parse(output)
    return await withTaskGroup(of: ChangedFile.self) { group -> [ChangedFile] in
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
      let order = Dictionary(uniqueKeysWithValues: parsed.enumerated().map { ($1.path, $0) })
      out.sort { (order[$0.path] ?? 0) < (order[$1.path] ?? 0) }
      return out
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
      switch diffMode {
      case .workingTree:
        // `cached` is false here — the client diffs against HEAD so
        // staged-only changes show up too.
        diffText = try await gitClient.diffForFile(worktreeURL, file.path, false)
      case .branchVsBase:
        guard let base = resolvedBaseRef else {
          diffText = ""
          return
        }
        diffText = try await gitClient.diffForFileAgainstBase(worktreeURL, file.path, base)
      }
    } catch {
      diffText = ""
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - File row

private enum QuickDiffFileActionError: LocalizedError {
  case absolutePath(String)
  case pathEscapesWorktree(String)

  var errorDescription: String? {
    switch self {
    case .absolutePath(let path):
      "Refusing to modify absolute path: \(path)"
    case .pathEscapesWorktree(let path):
      "Refusing to modify path outside the worktree: \(path)"
    }
  }
}

private struct FileRow: View {
  let file: ChangedFile

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: file.status.systemImage)
        .foregroundStyle(iconColor)
        .font(.body)
        .accessibilityLabel(file.status.accessibilityLabel)
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
