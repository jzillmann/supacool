import ComposableArchitecture
import SwiftUI

/// The Linear Inbox sheet. A two-tab dialog: the **Tickets** tab holds the
/// pasted-ticket overview; the **New Terminal** tab appears only while a
/// session is being configured (the embedded `NewTerminalSheet`), so the
/// user never juggles two stacked dialogs.
struct LinearInboxSheet: View {
  @Bindable var store: StoreOf<LinearInboxFeature>

  var body: some View {
    TabView(selection: $store.selectedTab) {
      inboxTab
        .tabItem { Label("Tickets", systemImage: "tray.full") }
        .tag(LinearInboxFeature.Tab.inbox)

      if let newTerminalStore = store.scope(state: \.newTerminal, action: \.newTerminal.presented) {
        NewTerminalSheet(store: newTerminalStore)
          .tabItem { Label("New Terminal", systemImage: "plus.square") }
          .tag(LinearInboxFeature.Tab.newTerminal)
      }
    }
    .frame(width: 660, height: 580)
    // Refresh state/assignee/title (and the done count) on open so the
    // inbox never shows stale cache.
    .task { await store.send(.task).finish() }
  }

  // MARK: - Tickets tab

  private var inboxTab: some View {
    VStack(spacing: 0) {
      header
      Divider()
      importField
      if let message = store.errorMessage {
        errorBanner(message)
      }
      Divider()
      if !store.tickets.isEmpty {
        doneFilterBar
      }
      ticketList
    }
  }

  /// "N/M done" progress link — toggles whether completed/canceled tickets
  /// are shown, so the list can read as a worklist of what's left.
  private var doneFilterBar: some View {
    HStack {
      Button {
        store.send(.toggleShowDone)
      } label: {
        Label(
          "\(store.doneCount)/\(store.tickets.count) done",
          systemImage: store.showDone ? "eye" : "eye.slash"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .disabled(store.doneCount == 0)
      .help(store.showDone ? "Hide done tickets" : "Show done tickets")
      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
  }

  private var header: some View {
    HStack {
      Label("Linear Inbox", systemImage: "tray.full")
        .font(.headline)
      Spacer()
      Button {
        store.send(.refreshAllTapped)
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Re-fetch state, assignee and titles for every ticket")
      .disabled(store.tickets.isEmpty || !store.fetchingTicketIDs.isEmpty)

      Button {
        store.send(.closeTapped)
      } label: {
        Label("Done", systemImage: "xmark.circle.fill")
          .labelStyle(.iconOnly)
      }
      .help("Close the inbox (your tickets are saved)")
      .keyboardShortcut(.cancelAction)
    }
    .padding()
  }

  private var importField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Paste Linear ticket links")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      TextEditor(text: $store.pasteText)
        .font(.system(.body, design: .monospaced))
        .frame(height: 72)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(.separator)
        )
      HStack {
        Spacer()
        Button("Replace list") {
          store.send(.importTapped(replace: true))
        }
        .help("Replace the inbox with the pasted tickets (keeps progress on surviving ones)")
        .disabled(store.pasteText.isEmpty)

        Button("Add to inbox") {
          store.send(.importTapped(replace: false))
        }
        .help("Add the pasted tickets to the inbox without removing existing ones")
        .keyboardShortcut(.defaultAction)
        .disabled(store.pasteText.isEmpty)
      }
    }
    .padding([.horizontal, .bottom])
    .padding(.top, 4)
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        store.send(.clearError)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Dismiss")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.orange.opacity(0.08))
  }

  @ViewBuilder
  private var ticketList: some View {
    if store.tickets.isEmpty {
      ContentUnavailableView(
        "No tickets yet",
        systemImage: "tray",
        description: Text("Paste one or more Linear issue links above to get started.")
      )
      .frame(maxHeight: .infinity)
    } else if store.visibleTickets.isEmpty {
      ContentUnavailableView(
        "All done",
        systemImage: "checkmark.circle",
        description: Text("Every ticket is completed. Tap “\(store.doneCount)/\(store.tickets.count) done” to show them.")
      )
      .frame(maxHeight: .infinity)
    } else {
      List {
        ForEach(store.visibleTickets) { ticket in
          LinearTicketRow(
            ticket: ticket,
            isExpanded: store.expandedTicketIDs.contains(ticket.identifier),
            isFetching: store.fetchingTicketIDs.contains(ticket.identifier),
            isAssigning: store.assigningTicketIDs.contains(ticket.identifier),
            hasLiveSession: store.state.liveStartedSessionID(for: ticket) != nil,
            onToggleExpanded: { store.send(.toggleExpanded(ticketID: ticket.identifier)) },
            onAssignToMe: { store.send(.assignToMeTapped(ticketID: ticket.identifier)) },
            onStartSession: { store.send(.startSessionTapped(ticketID: ticket.identifier)) },
            onOpenSession: { store.send(.openSessionTapped(ticketID: ticket.identifier)) },
            onRemove: { store.send(.removeTicketTapped(ticketID: ticket.identifier)) }
          )
        }
      }
      .listStyle(.inset)
    }
  }
}

/// One ticket row. Collapsed: id + title + state + assignee + status icons.
/// Expanded: description plus the action buttons.
private struct LinearTicketRow: View {
  let ticket: LinearTicket
  let isExpanded: Bool
  let isFetching: Bool
  let isAssigning: Bool
  /// True while the session spawned from this ticket still exists on the
  /// board — swaps "Start session" for "Open session".
  let hasLiveSession: Bool
  let onToggleExpanded: () -> Void
  let onAssignToMe: () -> Void
  let onStartSession: () -> Void
  let onOpenSession: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      summaryRow
      if isExpanded {
        expandedContent
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggleExpanded)
  }

  private var summaryRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(ticket.identifier)
        .font(.system(.body, design: .monospaced))
        .fontWeight(.semibold)

      Text(ticket.title ?? "Loading…")
        .lineLimit(1)
        .strikethrough(ticket.isDone, color: .secondary)
        .foregroundStyle(ticket.isDone || ticket.title == nil ? .secondary : .primary)

      Spacer(minLength: 8)

      if isFetching {
        ProgressView().controlSize(.small)
      }
      if ticket.startedAt != nil {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
          .help("You started a session on this ticket")
      }
      if let state = ticket.stateName {
        Text(state)
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
      }
      assigneeBadge
    }
  }

  @ViewBuilder
  private var assigneeBadge: some View {
    if ticket.assignedToMe {
      Label("You", systemImage: "person.fill")
        .font(.caption)
        .foregroundStyle(.tint)
        .labelStyle(.titleAndIcon)
    } else if let assignee = ticket.assigneeName {
      Text(assignee)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("Unassigned")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(descriptionText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) {
        if hasLiveSession {
          Button {
            onOpenSession()
          } label: {
            Label("Open session", systemImage: "terminal")
          }
          .help("Jump to the session already running for this ticket")
        } else {
          Button {
            onStartSession()
          } label: {
            Label("Start session", systemImage: "play.fill")
          }
          .help("Open a New Terminal pre-filled with “Fix \(ticket.identifier): …”")
        }

        Button {
          onAssignToMe()
        } label: {
          if isAssigning {
            ProgressView().controlSize(.small)
          } else {
            Label(ticket.assignedToMe ? "Assigned to you" : "Assign to me", systemImage: "person.crop.circle.badge.checkmark")
          }
        }
        .help("Assign this ticket to you in Linear")
        .disabled(isAssigning || ticket.assignedToMe)

        if let urlString = ticket.url, let url = URL(string: urlString) {
          Button {
            openInLinear(webURL: url)
          } label: {
            Label("Open in Linear", systemImage: "arrow.up.right.square")
          }
          .help("Open the ticket in the Linear desktop app")
        }

        Spacer()

        Button(role: .destructive) {
          onRemove()
        } label: {
          Label("Remove", systemImage: "trash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Remove this ticket from the inbox")
      }
      // The action row is its own tap target — don't let taps bubble up to
      // the row's expand/collapse gesture.
      .onTapGesture {}
    }
    .padding(.leading, 22)
  }

  private var descriptionText: String {
    if let summary = ticket.summary, !summary.isEmpty {
      return summary
    }
    return ticket.fetchedAt == nil ? "Loading description…" : "No description."
  }

  /// Linear's desktop app registers the `linear://` scheme; any
  /// `https://linear.app/…` URL becomes a deep link by swapping the prefix.
  /// Falls back to the browser when the desktop app isn't installed.
  private func openInLinear(webURL: URL) {
    let deepLink = URL(string: webURL.absoluteString.replacing("https://linear.app/", with: "linear://"))
    if let deepLink, deepLink != webURL, NSWorkspace.shared.urlForApplication(toOpen: deepLink) != nil {
      NSWorkspace.shared.open(deepLink)
    } else {
      NSWorkspace.shared.open(webURL)
    }
  }
}
