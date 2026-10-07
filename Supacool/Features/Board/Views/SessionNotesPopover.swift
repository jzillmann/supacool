import AppKit
import SwiftUI

/// Header chip for a session's pinned notes ("Pin Selection" in the
/// terminal's right-click menu). Shows the count; the popover lists the
/// notes newest first.
struct SessionNotesButton: View {
  let notes: [SessionNote]
  /// Whether the note's terminal still has a live tab to search in.
  let canJump: (SessionNote) -> Bool
  let onJump: (SessionNote) -> Void
  let onInsert: (SessionNote) -> Void
  let onRemove: (SessionNote) -> Void

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "pin.fill")
          .accessibilityHidden(true)
        Text("\(notes.count)")
          .monospacedDigit()
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help("Pinned notes — select terminal text, right-click, Pin Selection")
    .accessibilityLabel("\(notes.count) pinned notes")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      SessionNotesPopover(
        notes: notes,
        canJump: canJump,
        onJump: { note in
          isPresented = false
          onJump(note)
        },
        onInsert: { note in
          isPresented = false
          onInsert(note)
        },
        onRemove: onRemove
      )
    }
  }
}

struct SessionNotesPopover: View {
  let notes: [SessionNote]
  let canJump: (SessionNote) -> Bool
  let onJump: (SessionNote) -> Void
  let onInsert: (SessionNote) -> Void
  let onRemove: (SessionNote) -> Void

  @State private var expandedNoteID: SessionNote.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Image(systemName: "pin")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("Pinned notes")
          .font(.headline)
        Spacer()
        Text("\(notes.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider()
      if notes.isEmpty {
        Text("No pinned notes. Select terminal text, right-click, and choose Pin Selection.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
          .padding(.horizontal, 12)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(notes.reversed()) { note in
              row(for: note)
              Divider()
            }
          }
        }
      }
    }
    .frame(minWidth: 360, idealWidth: 460, maxWidth: 560, minHeight: 80, idealHeight: 360, maxHeight: 560)
  }

  private func row(for note: SessionNote) -> some View {
    let isExpanded = expandedNoteID == note.id
    let jumpable = canJump(note) && note.searchNeedle != nil
    return VStack(alignment: .leading, spacing: 6) {
      Button {
        expandedNoteID = isExpanded ? nil : note.id
      } label: {
        Text(note.text)
          .font(.callout.monospaced())
          .lineLimit(isExpanded ? nil : 4)
          .multilineTextAlignment(.leading)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Collapse" : "Show the full note")
      HStack(spacing: 12) {
        Text(note.createdAt.formatted(.relative(presentation: .named)))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Jump", systemImage: "arrow.down.forward.and.arrow.up.backward") { onJump(note) }
          .disabled(!jumpable)
          .help(
            jumpable
              ? "Scroll the terminal to this text"
              : "The terminal that printed this text is gone — its scrollback did not survive"
          )
        Button("Copy", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(note.text, forType: .string)
        }
        .help("Copy the note text")
        Button("Insert", systemImage: "text.insert") { onInsert(note) }
          .help("Type the note into the agent's prompt without sending it")
        Button(role: .destructive) {
          onRemove(note)
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .help("Delete this note")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.caption)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
