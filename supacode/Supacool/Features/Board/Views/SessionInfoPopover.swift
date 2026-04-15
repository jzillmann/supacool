import AppKit
import SwiftUI

/// Read-only summary of a session's initial config. Reached via the small
/// info (ⓘ) button that lives on each board card and in the full-screen
/// header — both surfaces reuse this view so the content stays consistent.
struct SessionInfoPopover: View {
  let session: AgentSession
  let repositoryName: String?
  let worktreeLabel: String?
  var onRerun: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var didCopyPrompt: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      promptBlock
      Divider()
      metadata
    }
    .padding(16)
    .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      Text(session.displayName)
        .font(.headline)
        .lineLimit(2)
    }
  }

  private var promptBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Label("Initial prompt", systemImage: "quote.opening")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if !session.initialPrompt.isEmpty {
          Button {
            copyPrompt()
          } label: {
            Image(systemName: didCopyPrompt ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help(didCopyPrompt ? "Prompt copied" : "Copy prompt")
        }
        if let onRerun {
          Button {
            onRerun()
            dismiss()
          } label: {
            Label("Rerun", systemImage: "arrow.clockwise")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help("Rerun with the same prompt")
        }
      }
      if session.initialPrompt.isEmpty {
        Text("(no prompt — raw terminal)")
          .font(.callout)
          .foregroundStyle(.tertiary)
      } else {
        ScrollView {
          Text(session.initialPrompt)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  @ViewBuilder
  private var metadata: some View {
    VStack(alignment: .leading, spacing: 6) {
      row(label: "Agent", value: AgentType.displayName(for: session.agent))
      if let repositoryName {
        row(label: "Repository", value: repositoryName)
      }
      if let worktreeLabel {
        row(label: "Worktree", value: worktreeLabel)
      } else {
        row(label: "Worktree", value: "— (repo root)")
      }
      row(label: "Created", value: Self.dateFormatter.string(from: session.createdAt))
      if let id = session.agentNativeSessionID, !id.isEmpty {
        row(label: "Resume id", value: id, monospaced: true)
      }
    }
  }

  private func row(label: String, value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 90, alignment: .leading)
      Text(value)
        .font(monospaced ? .caption.monospaced() : .callout)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .lineLimit(2)
      Spacer()
    }
  }

  private func copyPrompt() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(session.initialPrompt, forType: .string)
    didCopyPrompt = true
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      await MainActor.run { didCopyPrompt = false }
    }
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}
