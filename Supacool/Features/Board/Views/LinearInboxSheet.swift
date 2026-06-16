import ComposableArchitecture
import SwiftUI

/// The Linear Inbox sheet. A two-tab dialog: the **Tickets** tab holds the
/// pasted-ticket overview; the **New Terminal** tab appears only while a
/// session is being configured (the embedded `NewTerminalSheet`), so the
/// user never juggles two stacked dialogs.
struct LinearInboxSheet: View {
  @Bindable var store: StoreOf<LinearInboxFeature>

  var body: some View {
    // Hand-rolled tab switching instead of `TabView`: the macOS tab style
    // draws its own content bezel inside the sheet (a double border) and
    // floats a lone "Tickets" button when only one tab exists. A segmented
    // picker appears only while the New Terminal tab is alive.
    VStack(spacing: 0) {
      if store.hasNewTerminalTab {
        Picker("Tab", selection: $store.selectedTab) {
          Text("Tickets").tag(LinearInboxFeature.Tab.inbox)
          Text("New Terminal").tag(LinearInboxFeature.Tab.newTerminal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.top, 10)
      }
      if store.selectedTab == .newTerminal,
        let newTerminalStore = store.scope(state: \.newTerminal, action: \.newTerminal.presented)
      {
        NewTerminalSheet(store: newTerminalStore)
      } else {
        inboxTab
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
        Label(doneFilterLabel, systemImage: store.showDone ? "eye" : "eye.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .disabled(store.doneCount == 0 && store.hiddenCount == 0)
      .help(store.showDone ? "Hide done and hidden tickets" : "Show done and hidden tickets")
      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
  }

  private var doneFilterLabel: String {
    var label = "\(store.doneCount)/\(store.tickets.count) done"
    if store.hiddenCount > 0 {
      label += ", \(store.hiddenCount) hidden"
    }
    return label
  }

  private var header: some View {
    HStack {
      Label("Linear Inbox", systemImage: "tray.full")
        .font(.headline)
      if store.availableRepositories.count > 1 {
        Picker("Repository", selection: $store.selectedRepositoryID) {
          ForEach(store.availableRepositories) { repository in
            Text(repository.name).tag(Optional(repository.id))
          }
        }
        .labelsHidden()
        .fixedSize()
        .help("Switch which repository's Linear worklist you're triaging")
      }
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
        Button {
          store.send(.fetchRecentTapped)
        } label: {
          if store.isFetchingRecent {
            ProgressView()
              .controlSize(.small)
          } else {
            Label(
              "Last \(LinearInboxFeature.recentFetchLimit) created",
              systemImage: "clock.arrow.circlepath"
            )
          }
        }
        .help("Fetch the \(LinearInboxFeature.recentFetchLimit) most recently created Linear tickets and add them to the inbox")
        .disabled(store.isFetchingRecent)

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
        description: Text(
          "Paste one or more Linear issue links above, or fetch the last "
            + "\(LinearInboxFeature.recentFetchLimit) created tickets."
        )
      )
      .frame(maxHeight: .infinity)
    } else if store.visibleTickets.isEmpty {
      ContentUnavailableView(
        "All done",
        systemImage: "checkmark.circle",
        description: Text("Every ticket is done or hidden. Tap “\(doneFilterLabel)” to show them.")
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
            onToggleHidden: { store.send(.toggleHideTapped(ticketID: ticket.identifier)) },
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
  let onToggleHidden: () -> Void
  let onAssignToMe: () -> Void
  let onStartSession: () -> Void
  let onOpenSession: () -> Void
  let onRemove: () -> Void

  @State private var isHovering = false

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
    .onHover { isHovering = $0 }
  }

  private var summaryRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(ticket.identifier)
        .font(.system(.body, design: .monospaced))
        .fontWeight(.semibold)
        .opacity(ticket.isHidden ? 0.5 : 1)

      Text(ticket.title ?? "Loading…")
        .lineLimit(1)
        .strikethrough(ticket.isDone, color: .secondary)
        .foregroundStyle(ticket.isDone || ticket.title == nil ? .secondary : .primary)
        .opacity(ticket.isHidden ? 0.5 : 1)

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
      if isAssigning {
        ProgressView().controlSize(.small)
      } else if !ticket.assignedToMe {
        Button {
          onAssignToMe()
        } label: {
          Image(systemName: "person.crop.circle.badge.checkmark")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Assign this ticket to you in Linear")
      }
      assigneeBadge
      hoverControls
    }
  }

  /// Hide and remove, reachable without expanding the row. Revealed on
  /// hover; the unhide eye stays visible so a hidden row (shown via the
  /// done filter) is never stuck.
  private var hoverControls: some View {
    HStack(spacing: 4) {
      Button {
        onToggleHidden()
      } label: {
        Image(systemName: ticket.isHidden ? "eye" : "eye.slash")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help(ticket.isHidden ? "Unhide this ticket" : "Hide this ticket from the list (kept in the inbox)")

      Button(role: .destructive) {
        onRemove()
      } label: {
        Image(systemName: "xmark")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Remove this ticket from the inbox")
    }
    .opacity(isHovering || ticket.isHidden ? 1 : 0)
    .allowsHitTesting(isHovering || ticket.isHidden)
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
      Group {
        if let summary = ticket.summary, !summary.isEmpty {
          // Linear descriptions are markdown; render the structure instead
          // of showing raw `**`/`[…](…)` markup.
          MarkdownText(source: summary)
        } else {
          Text(ticket.fetchedAt == nil ? "Loading description…" : "No description.")
        }
      }
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
