import ComposableArchitecture
import SwiftUI

/// The Linear Inbox sheet. A two-tab dialog: the **Tickets** tab holds the
/// worklist — a **Recent** source (Linear's latest-created feed, auto-loaded
/// on open) and a **Pasted** source (hand-curated links), toggled by a
/// segmented control and narrowed by quick filters. The **New Terminal** tab
/// appears only while a session is being configured (the embedded
/// `NewTerminalSheet`), so the user never juggles two stacked dialogs.
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
    .frame(width: 820, height: 580)
    // Refresh state/assignee/title (and the done count) on open so the
    // inbox never shows stale cache.
    .task { await store.send(.task).finish() }
  }

  // MARK: - Tickets tab

  private var inboxTab: some View {
    VStack(spacing: 0) {
      header
      Divider()
      sourcePicker
      // The paste field is the "Pasted" source's editor — only shown there.
      if store.source == .pasted {
        importField
      }
      if let message = store.errorMessage {
        errorBanner(message)
      }
      Divider()
      filterBar
      ticketList
    }
  }

  /// Recent vs Pasted. Recent auto-loads Linear's latest-created feed on open;
  /// Pasted shows the hand-curated worklist. The choice persists across opens.
  private var sourcePicker: some View {
    Picker(
      "Source",
      selection: Binding(
        get: { store.source },
        set: { store.send(.sourceChanged($0)) }
      )
    ) {
      Text("Recent").tag(LinearTicketSource.recent)
      Text("Pasted").tag(LinearTicketSource.pasted)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .padding(.vertical, 8)
    .help("Switch between Linear's most-recently-created tickets and your pasted worklist")
  }

  /// Quick filters: narrow to your own tickets, and reveal done / ignored rows.
  private var filterBar: some View {
    HStack(spacing: 8) {
      filterToggle(
        "Assigned to me",
        systemImage: "person.fill",
        isOn: store.assignedToMeOnly,
        count: store.assignedToMeCount,
        help: "Show only tickets assigned to you",
        onToggle: { store.send(.toggleAssignedToMe) }
      )
      filterToggle(
        "Hide in progress",
        systemImage: "hammer",
        isOn: store.hideInProgress,
        count: store.inProgressCount,
        help: "Hide tickets already in progress or in review",
        onToggle: { store.send(.toggleHideInProgress) }
      )
      filterToggle(
        "Hide linked",
        systemImage: "link",
        isOn: store.hideLinked,
        count: store.linkedCount,
        help: "Hide tickets that already have a running session",
        onToggle: { store.send(.toggleHideLinked) }
      )
      filterToggle(
        "Done",
        systemImage: "checkmark.circle",
        isOn: store.showDone,
        count: store.doneCount,
        help: "Reveal completed and canceled tickets",
        onToggle: { store.send(.toggleShowDone) }
      )
      filterToggle(
        "Ignored",
        systemImage: "eye.slash",
        isOn: store.showIgnored,
        count: store.ignoredCount,
        help: "Reveal tickets you've ignored",
        onToggle: { store.send(.toggleShowIgnored) }
      )
      Spacer()
      if store.isFetchingRecent {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
  }

  private func filterToggle(
    _ title: String,
    systemImage: String,
    isOn: Bool,
    count: Int,
    help: String,
    onToggle: @escaping () -> Void
  ) -> some View {
    Toggle(isOn: Binding(get: { isOn }, set: { _ in onToggle() })) {
      HStack(spacing: 4) {
        Image(systemName: systemImage)
        Text(title)
        if count > 0 {
          Text("\(count)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
    }
    .toggleStyle(.button)
    .controlSize(.small)
    .help(help)
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
      .help(
        store.source == .recent
          ? "Re-pull Linear's most-recently-created tickets"
          : "Re-fetch state, assignee and titles for every ticket"
      )
      .disabled(
        store.isFetchingRecent
          || !store.fetchingTicketIDs.isEmpty
          || (store.source == .pasted && store.tickets.isEmpty)
      )

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
        .help("Replace the pasted worklist with these tickets (keeps progress on surviving ones)")
        .disabled(store.pasteText.isEmpty)

        Button("Add to list") {
          store.send(.importTapped(replace: false))
        }
        .help("Add these tickets to the pasted worklist without removing existing ones")
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
      if store.isFetchingRecent {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading recent tickets…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.source == .recent {
        ContentUnavailableView(
          "No recent tickets",
          systemImage: "clock",
          description: Text(
            "Nothing recently created for this repository's Linear team, "
              + "or no team key is set under Settings → repository → Linear."
          )
        )
        .frame(maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "No pasted tickets",
          systemImage: "tray",
          description: Text("Paste one or more Linear issue links above to build your worklist.")
        )
        .frame(maxHeight: .infinity)
      }
    } else if store.visibleTickets.isEmpty {
      ContentUnavailableView(
        "Nothing to show",
        systemImage: "line.3.horizontal.decrease.circle",
        description: Text("Every ticket is filtered out — toggle the quick filters above to reveal them.")
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
            hasLiveSession: store.state.liveLinkedSessionID(for: ticket) != nil,
            onToggleExpanded: { store.send(.toggleExpanded(ticketID: ticket.identifier)) },
            onToggleIgnored: { store.send(.toggleIgnoreTapped(ticketID: ticket.identifier)) },
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
  let onToggleIgnored: () -> Void
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
      if hasLiveSession {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
          .help("A session for this ticket is running on the board")
      }
      if let creator = ticket.creatorName, !creator.isEmpty {
        Label(creator, systemImage: "square.and.pencil")
          .labelStyle(.titleAndIcon)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .help("Created by \(creator)")
      }
      if let createdAt = ticket.createdAt {
        Text(compactAge(since: createdAt))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
          .help("Created \(createdAt.formatted(date: .abbreviated, time: .shortened))")
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

  /// Ignore and remove, reachable without expanding the row. Revealed on
  /// hover; the un-ignore eye stays visible so an ignored row (shown via the
  /// "Ignored" filter) is never stuck.
  private var hoverControls: some View {
    HStack(spacing: 4) {
      Button {
        onToggleIgnored()
      } label: {
        Image(systemName: ticket.isHidden ? "eye" : "eye.slash")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help(ticket.isHidden ? "Un-ignore this ticket" : "Ignore this ticket (kept in the inbox)")

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

  /// Compact "time since created" badge — `5m`, `3h`, `2d`, `4w`, `6mo`, `1y`.
  /// Coarse on purpose: the overview only needs a glance at how fresh a ticket
  /// is, with the exact timestamp available on hover.
  private func compactAge(since created: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(created))
    let minute = 60.0, hour = 3_600.0, day = 86_400.0, week = 7 * day, month = 30 * day, year = 365 * day
    switch seconds {
    case ..<minute: return "now"
    case ..<hour: return "\(Int(seconds / minute))m"
    case ..<day: return "\(Int(seconds / hour))h"
    case ..<week: return "\(Int(seconds / day))d"
    case ..<month: return "\(Int(seconds / week))w"
    case ..<year: return "\(Int(seconds / month))mo"
    default: return "\(Int(seconds / year))y"
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
