import AppKit
import ComposableArchitecture
import SwiftUI

/// Small toolbar chip that shows the aggregate RSS of Supacool plus
/// every descendant process it's spawned (shells, agents, whatever they
/// exec). Tapping the chip opens the analysis sheet with a breakdown
/// per top-level subtree — the same process-tree walk I run by hand
/// during incidents. Polls every 20 s; runs the ps call off-main.
struct FootprintChip: View {
  /// Warn when the total RSS crosses this. 12 GB picks up the 8–16 GB
  /// scenarios that routinely accompany the go-vet-Pulumi incident and
  /// leaves room for normal multi-session usage.
  private static let warnThresholdBytes: UInt64 = 12 * 1024 * 1024 * 1024
  /// Critical threshold — highlight in red.
  private static let criticalThresholdBytes: UInt64 = 24 * 1024 * 1024 * 1024
  /// Sampling cadence. 20 s is plenty responsive for spotting runaways
  /// while keeping the cost of a `ps -ax` walk negligible.
  private static let pollInterval: Duration = .seconds(20)

  /// Shared, observable footprint store. One instance is created by the
  /// board and passed down via environment; cards read from it without
  /// starting their own samplers.
  let store: SessionFootprintStore

  @State private var isSheetPresented: Bool = false

  var body: some View {
    Button {
      isSheetPresented = true
      Task { await store.refresh() }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "memorychip")
          .font(.caption)
        Text(displayTotal)
          .font(.caption.monospacedDigit())
      }
      .padding(.horizontal, 2)
      .foregroundStyle(tint)
    }
    .buttonStyle(.bordered)
    .help(helpText)
    .task { await pollLoop() }
    .sheet(isPresented: $isSheetPresented) {
      FootprintAnalysisSheet(
        snapshot: store.snapshot,
        isRefreshing: store.isRefreshing,
        onRefresh: { Task { await store.refresh() } },
        onDismiss: { isSheetPresented = false }
      )
    }
  }

  private var displayTotal: String {
    guard let snapshot = store.snapshot else { return "—" }
    return FootprintChip.formatBytes(snapshot.totalBytes)
  }

  private var tint: Color {
    guard let snapshot = store.snapshot else { return .secondary }
    if snapshot.totalBytes >= FootprintChip.criticalThresholdBytes { return .red }
    if snapshot.totalBytes >= FootprintChip.warnThresholdBytes { return .orange }
    return .secondary
  }

  private var helpText: String {
    guard let snapshot = store.snapshot else {
      return "Sampling memory footprint of Supacool + its descendants…"
    }
    return """
      Supacool + \(snapshot.descendantCount) descendant process\
      \(snapshot.descendantCount == 1 ? "" : "es"): \
      \(FootprintChip.formatBytes(snapshot.totalBytes)).
      Click to analyze.
      """
  }

  private func pollLoop() async {
    await store.refresh()
    while !Task.isCancelled {
      try? await Task.sleep(for: FootprintChip.pollInterval)
      await store.refresh()
    }
  }

  static func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
  }
}

/// Full-window sheet that presents the current footprint snapshot as a
/// ranked list of top-level subtrees. Each row shows aggregate bytes
/// and the single heaviest descendant — typically enough context to
/// recognize patterns like the centrum-backend-pre-push → go-vet chain.
struct FootprintAnalysisSheet: View {
  let snapshot: ProcessFootprintSnapshot?
  let isRefreshing: Bool
  let onRefresh: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if let snapshot, !snapshot.subtrees.isEmpty {
        subtreeList(snapshot: snapshot)
      } else if snapshot == nil && isRefreshing {
        sampling
      } else {
        emptyState
      }
      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 560)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Memory footprint")
          .font(.title2.weight(.semibold))
        if let snapshot {
          Text(headerSubtitle(snapshot))
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          Text("Sampling…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if isRefreshing {
        ProgressView().controlSize(.small)
      }
      Button {
        onRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help("Re-sample the process tree")
    }
    .padding(18)
  }

  @ViewBuilder
  private func subtreeList(snapshot: ProcessFootprintSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "app.badge")
            .foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 1) {
            Text("Supacool (this app)")
              .font(.callout.weight(.medium))
            Text("Root process")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(FootprintChip.formatBytes(snapshot.rootBytes))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        Divider()
        ForEach(snapshot.subtrees) { subtree in
          SubtreeRow(subtree: subtree)
          Divider()
        }
      }
    }
  }

  private var sampling: some View {
    VStack(spacing: 10) {
      ProgressView()
      Text("Sampling process tree…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.seal")
        .font(.largeTitle)
        .foregroundStyle(.green)
      Text("No descendant processes")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Button("Copy report") {
        if let snapshot {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(Self.report(for: snapshot), forType: .string)
        }
      }
      .disabled(snapshot == nil)
      .help("Copy a plain-text breakdown of the current snapshot for a bug report or ticket")
      Spacer()
      Button("Done", action: onDismiss)
        .keyboardShortcut(.defaultAction)
    }
    .padding(18)
  }

  private func headerSubtitle(_ snapshot: ProcessFootprintSnapshot) -> String {
    let total = FootprintChip.formatBytes(snapshot.totalBytes)
    let app = FootprintChip.formatBytes(snapshot.rootBytes)
    let descendants = FootprintChip.formatBytes(snapshot.descendantBytes)
    return
      "\(total) total — \(app) app + \(descendants) across \(snapshot.descendantCount) descendant process\(snapshot.descendantCount == 1 ? "" : "es")"
  }

  /// Plain-text report pasted into a ticket body. Deliberately wide
  /// enough that PID + command don't truncate in most markdown
  /// renderers.
  static func report(for snapshot: ProcessFootprintSnapshot) -> String {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .medium
    var lines: [String] = []
    lines.append("Supacool memory footprint — \(df.string(from: snapshot.sampledAt))")
    lines.append("Total: \(FootprintChip.formatBytes(snapshot.totalBytes))")
    lines.append("  App:        \(FootprintChip.formatBytes(snapshot.rootBytes))")
    lines.append(
      "  Descendants: \(FootprintChip.formatBytes(snapshot.descendantBytes)) "
        + "across \(snapshot.descendantCount) processes"
    )
    if !snapshot.sessionFootprints.isEmpty {
      lines.append("")
      lines.append("Per-session attribution (anchor PID → aggregate RSS):")
      let sorted = snapshot.sessionFootprints.sorted { $0.value.aggregatedBytes > $1.value.aggregatedBytes }
      for (sessionID, fp) in sorted {
        lines.append(
          "  \(sessionID.uuidString.prefix(8))… "
            + "anchor PID \(fp.anchorPID): "
            + "\(FootprintChip.formatBytes(fp.aggregatedBytes)) "
            + "(\(fp.processCount) process\(fp.processCount == 1 ? "" : "es"))"
        )
      }
    }
    lines.append("")
    lines.append("Top-level subtrees (sorted by aggregate RSS):")
    for (index, sub) in snapshot.subtrees.enumerated() {
      lines.append("")
      lines.append(
        "[\(index + 1)] PID \(sub.id) — "
          + "\(FootprintChip.formatBytes(sub.aggregatedBytes)) "
          + "(\(sub.processCount) process\(sub.processCount == 1 ? "" : "es"))"
      )
      lines.append("    \(sub.rootCommand)")
      if let heavy = sub.heaviestLeaf, heavy.pid != sub.id {
        lines.append(
          "    heaviest: PID \(heavy.pid) \(FootprintChip.formatBytes(heavy.rssBytes))"
        )
        lines.append("      \(heavy.command)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

/// One row per top-level subtree. Shows aggregate RSS prominently, with
/// the heaviest descendant command listed below — that's usually what
/// you're looking for ("ah, it's go vet again").
private struct SubtreeRow: View {
  let subtree: ProcessFootprintSnapshot.Subtree

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: subtreeIcon)
          .foregroundStyle(iconColor)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(prettyCommand(subtree.rootCommand))
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
          Text(
            "PID \(subtree.id) · \(subtree.processCount) process"
              + (subtree.processCount == 1 ? "" : "es")
          )
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 8)
        Text(FootprintChip.formatBytes(subtree.aggregatedBytes))
          .font(.callout.weight(.semibold).monospacedDigit())
          .foregroundStyle(weightTint)
      }
      if let heavy = subtree.heaviestLeaf, heavy.pid != subtree.id {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: "arrow.turn.down.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 22)
          Text(prettyCommand(heavy.command))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          Text(FootprintChip.formatBytes(heavy.rssBytes))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
  }

  /// Rough command-to-icon mapping. Deliberately lax — when unsure we
  /// fall back to a generic terminal glyph rather than misleading the
  /// user with an icon that implies we know what the subtree is.
  private var subtreeIcon: String {
    let command = subtree.rootCommand.lowercased()
    if command.contains("login") || command.contains("zsh") || command.contains("bash") {
      return "apple.terminal"
    }
    if command.contains("node") { return "hexagon" }
    if command.contains("python") { return "curlybraces" }
    if command.contains("git ") || command.hasSuffix("/git") { return "arrow.triangle.branch" }
    if command.contains("go ") || command.contains("/go") { return "hammer" }
    return "app.dashed"
  }

  private var iconColor: Color {
    if subtree.aggregatedBytes >= 2 * 1024 * 1024 * 1024 { return .orange }
    if subtree.aggregatedBytes >= 500 * 1024 * 1024 { return .yellow }
    return .secondary
  }

  private var weightTint: Color {
    if subtree.aggregatedBytes >= 2 * 1024 * 1024 * 1024 { return .orange }
    return .primary
  }

  /// Lightweight command pretty-printer: strip very long absolute paths
  /// down to the leaf executable name while preserving arguments, so
  /// `/Users/jz/go/.../compile -o /tmp/... pkg/file.go …` doesn't eat
  /// the whole row. Keeps the first 80 chars of the normalized string.
  private func prettyCommand(_ raw: String) -> String {
    var parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    if let first = parts.first, first.contains("/") {
      let leaf = URL(fileURLWithPath: String(first)).lastPathComponent
      parts[0] = Substring(leaf)
    }
    let normalized = parts.joined(separator: " ")
    return String(normalized.prefix(180))
  }
}
