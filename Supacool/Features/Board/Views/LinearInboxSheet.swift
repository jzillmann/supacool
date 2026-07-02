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
      // The paste field is the "Pasted" source's editor — only shown there,
      // and only in list mode: focus mode has no room for it and triaging
      // one card at a time isn't when you're curating the pasted set.
      if store.source == .pasted, store.viewMode == .list {
        importField
      }
      if let message = store.errorMessage {
        errorBanner(message)
      }
      Divider()
      filterBar
      if store.viewMode == .focus {
        focusContent
      } else {
        ticketList
      }
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

  /// Quick filters: two multi-select chip groups (assignee, status) — empty
  /// selection in a group means "show all" for that group — plus two
  /// standalone toggles. Visually grouped with dividers so the two
  /// independent chip groups don't read as one long row of unrelated toggles.
  private var filterBar: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        assigneeChip(.me, title: "Me", systemImage: "person.fill", help: "Show tickets assigned to you")
        assigneeChip(
          .unassigned,
          title: "Unassigned",
          systemImage: "person.crop.circle.dashed",
          help: "Show tickets nobody is assigned to"
        )
        assigneeChip(
          .others,
          title: "Others",
          systemImage: "person.2.fill",
          help: "Show tickets assigned to someone else"
        )
      }
      Divider().frame(height: 14)
      HStack(spacing: 6) {
        statusChip(.todo, title: "Todo", systemImage: "circle", help: "Show tickets not yet started")
        statusChip(.active, title: "Active", systemImage: "hammer", help: "Show tickets in progress or in review")
        statusChip(.done, title: "Done", systemImage: "checkmark.circle", help: "Show completed and canceled tickets")
      }
      Divider().frame(height: 14)
      filterToggle(
        "Hide linked",
        systemImage: "link",
        isOn: store.hideLinked,
        count: store.linkedCount,
        help: "Hide tickets that already have a running session",
        onToggle: { store.send(.toggleHideLinked) }
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

  private func assigneeChip(
    _ bucket: LinearInboxFeature.AssigneeBucket,
    title: String,
    systemImage: String,
    help: String
  ) -> some View {
    let count: Int =
      switch bucket {
      case .me: store.meCount
      case .unassigned: store.unassignedCount
      case .others: store.othersCount
      }
    return filterToggle(
      title,
      systemImage: systemImage,
      isOn: store.selectedAssigneeBuckets.contains(bucket),
      count: count,
      help: help,
      onToggle: { store.send(.toggleAssigneeFilter(bucket)) }
    )
  }

  private func statusChip(
    _ bucket: LinearInboxFeature.StatusBucket,
    title: String,
    systemImage: String,
    help: String
  ) -> some View {
    let count: Int =
      switch bucket {
      case .todo: store.todoCount
      case .active: store.activeCount
      case .done: store.doneCount
      }
    return filterToggle(
      title,
      systemImage: systemImage,
      isOn: store.selectedStatusBuckets.contains(bucket),
      count: count,
      help: help,
      onToggle: { store.send(.toggleStatusFilter(bucket)) }
    )
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
      viewModePicker
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

  /// List vs. focus (triage) mode. Two icon-only buttons rather than a
  /// `Picker(.segmented)` so each mode carries its own `.help()` tooltip —
  /// segmented pickers on macOS don't reliably surface per-segment help text.
  private var viewModePicker: some View {
    HStack(spacing: 2) {
      viewModeButton(
        .list,
        systemImage: "list.bullet",
        help: "List — scroll through the full worklist"
      )
      viewModeButton(
        .focus,
        systemImage: "rectangle.portrait.on.rectangle.portrait",
        help: "Focus — triage one ticket at a time (→ skip, ← back)"
      )
    }
    .padding(2)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
  }

  private func viewModeButton(_ mode: LinearInboxViewMode, systemImage: String, help: String) -> some View {
    let isSelected = store.viewMode == mode
    return Button {
      store.send(.viewModeChanged(mode))
    } label: {
      Image(systemName: systemImage)
        .frame(width: 22, height: 18)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(isSelected ? .primary : .secondary)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 4).fill(.background)
      }
    }
    .help(help)
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

  /// No tickets in the bucket at all (before any quick filter). Shared
  /// between list and focus mode.
  @ViewBuilder
  private var emptyTicketsView: some View {
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
  }

  /// Tickets exist, but every one is filtered out. Shared between list and
  /// focus mode.
  private var nothingToShowView: some View {
    ContentUnavailableView(
      "Nothing to show",
      systemImage: "line.3.horizontal.decrease.circle",
      description: Text("Every ticket is filtered out — toggle the quick filters above to reveal them.")
    )
    .frame(maxHeight: .infinity)
  }

  @ViewBuilder
  private var ticketList: some View {
    if store.tickets.isEmpty {
      emptyTicketsView
    } else if store.visibleTickets.isEmpty {
      nothingToShowView
    } else {
      List {
        ForEach(store.visibleEntries) { entry in
          switch entry {
          case .ticket(let ticket):
            ticketRow(ticket)
          case .group(let group):
            LinearGroupRow(
              group: group,
              isExpanded: store.expandedGroupIDs.contains(group.parentIdentifier),
              onToggleExpanded: { store.send(.toggleGroupExpanded(parentID: group.parentIdentifier)) }
            )
            if store.expandedGroupIDs.contains(group.parentIdentifier) {
              ForEach(group.children) { ticket in
                ticketRow(ticket)
                  .padding(.leading, 18)
              }
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }

  /// A single ticket row, wired to the store. Shared between top-level rows
  /// and the children revealed under an expanded parent group.
  private func ticketRow(_ ticket: LinearTicket) -> some View {
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

  // MARK: - Focus (triage) mode

  /// One ticket at a time, cycled with keyboard/single clicks. The deck is
  /// exactly ``LinearInboxFeature/State/visibleTickets`` — no grouping — so
  /// sub-issues triage individually here even when the list bundles them.
  @ViewBuilder
  private var focusContent: some View {
    if store.tickets.isEmpty {
      emptyTicketsView
    } else if store.visibleTickets.isEmpty {
      nothingToShowView
    } else if let ticket = store.focusedTicket {
      FocusTicketCard(
        ticket: ticket,
        position: store.focusIndexClamped + 1,
        total: store.visibleTickets.count,
        isAssigning: store.assigningTicketIDs.contains(ticket.identifier),
        hasLiveSession: store.state.liveLinkedSessionID(for: ticket) != nil,
        canRetreat: store.focusIndexClamped > 0,
        onStartSession: { store.send(.startSessionTapped(ticketID: ticket.identifier)) },
        onOpenSession: { store.send(.openSessionTapped(ticketID: ticket.identifier)) },
        onAdvance: { store.send(.focusAdvance) },
        onRetreat: { store.send(.focusRetreat) },
        onToggleIgnored: { store.send(.toggleIgnoreTapped(ticketID: ticket.identifier)) },
        onAssignToMe: { store.send(.assignToMeTapped(ticketID: ticket.identifier)) },
        onRemove: { store.send(.removeTicketTapped(ticketID: ticket.identifier)) }
      )
    } else {
      FocusDeckFinishedCard(
        onRestart: { store.send(.focusRestart) },
        onRetreat: { store.send(.focusRetreat) }
      )
    }
  }
}

/// The header for a bundle of sub-issues sharing one parent. Collapsed by
/// default: shows the parent key, title and a sub-issue count. Tapping toggles
/// the children, which render as ordinary rows indented beneath it.
private struct LinearGroupRow: View {
  let group: LinearTicketGroup
  let isExpanded: Bool
  let onToggleExpanded: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)

      Image(systemName: "square.stack.3d.up.fill")
        .foregroundStyle(.secondary)

      Text(group.parentIdentifier)
        .font(.system(.body, design: .monospaced))
        .fontWeight(.semibold)

      Text(group.parentTitle ?? "Parent issue")
        .lineLimit(1)
        .foregroundStyle(group.parentTitle == nil ? .secondary : .primary)

      Spacer(minLength: 8)

      Text("\(group.children.count) sub-issues")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggleExpanded)
    .help("Show the \(group.children.count) sub-issues of \(group.parentIdentifier)")
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
}

/// Linear's desktop app registers the `linear://` scheme; any
/// `https://linear.app/…` URL becomes a deep link by swapping the prefix.
/// Falls back to the browser when the desktop app isn't installed. Shared
/// between the list row's expanded content and the focus card's action bar.
fileprivate func openInLinear(webURL: URL) {
  let deepLink = URL(string: webURL.absoluteString.replacing("https://linear.app/", with: "linear://"))
  if let deepLink, deepLink != webURL, NSWorkspace.shared.urlForApplication(toOpen: deepLink) != nil {
    NSWorkspace.shared.open(deepLink)
  } else {
    NSWorkspace.shared.open(webURL)
  }
}

/// One ticket shown full-card in focus mode: position, identity, state,
/// assignee and age up top; the full title and description below; a fixed
/// action bar at the bottom so the controls never move as the deck advances.
private struct FocusTicketCard: View {
  let ticket: LinearTicket
  /// 1-based position in the deck, e.g. `3` of `total == 24`.
  let position: Int
  let total: Int
  let isAssigning: Bool
  let hasLiveSession: Bool
  let canRetreat: Bool
  let onStartSession: () -> Void
  let onOpenSession: () -> Void
  let onAdvance: () -> Void
  let onRetreat: () -> Void
  let onToggleIgnored: () -> Void
  let onAssignToMe: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          topRow
          if let parent = ticket.parentIdentifier, !parent.isEmpty {
            parentChip(parent)
          }
          Text(ticket.title ?? "Loading…")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ticket.title == nil ? .secondary : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Group {
            if let summary = ticket.summary, !summary.isEmpty {
              // Linear descriptions are markdown; render the structure
              // instead of showing raw `**`/`[…](…)` markup.
              MarkdownText(source: summary)
            } else {
              Text(ticket.fetchedAt == nil ? "Loading description…" : "No description.")
            }
          }
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
      }
      Divider()
      actionBar
    }
  }

  private var topRow: some View {
    HStack(spacing: 10) {
      Text("\(position) of \(total)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Text(ticket.identifier)
        .font(.system(.body, design: .monospaced))
        .fontWeight(.semibold)

      if let state = ticket.stateName {
        Text(state)
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
      }

      assigneeBadge

      if let creator = ticket.creatorName, !creator.isEmpty {
        Text("by \(creator)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      if let createdAt = ticket.createdAt {
        Text("open \(spelledOutAge(since: createdAt))")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .help("Created \(createdAt.formatted(date: .abbreviated, time: .shortened))")
      }

      if hasLiveSession {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
          .help("A session for this ticket is running on the board")
      }

      Spacer(minLength: 0)
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

  private func parentChip(_ parent: String) -> some View {
    Text("Sub-issue of \(parent)\(ticket.parentTitle.map { " — \($0)" } ?? "")")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }

  private var actionBar: some View {
    HStack(spacing: 8) {
      if hasLiveSession {
        Button {
          onOpenSession()
        } label: {
          Label("Open session", systemImage: "terminal")
        }
        .keyboardShortcut(.defaultAction)
        .help("Jump to the session already running for this ticket (⏎)")
      } else {
        Button {
          onStartSession()
        } label: {
          Label("Start session", systemImage: "play.fill")
        }
        .keyboardShortcut(.defaultAction)
        .help("Open a New Terminal pre-filled with “Fix \(ticket.identifier): …” (⏎)")
      }

      Button {
        onRetreat()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .keyboardShortcut(.leftArrow, modifiers: [])
      .disabled(!canRetreat)
      .help("Back to the previous ticket (←)")

      Button {
        onAdvance()
      } label: {
        Label("Skip", systemImage: "chevron.right")
      }
      .keyboardShortcut(.rightArrow, modifiers: [])
      .help("Skip to the next ticket (→)")

      Button {
        onToggleIgnored()
      } label: {
        Label(ticket.isHidden ? "Un-ignore" : "Ignore", systemImage: ticket.isHidden ? "eye" : "eye.slash")
      }
      .keyboardShortcut("i", modifiers: [])
      .help(ticket.isHidden ? "Un-ignore this ticket (I)" : "Ignore this ticket, kept in the inbox (I)")

      Button {
        onAssignToMe()
      } label: {
        if isAssigning {
          ProgressView().controlSize(.small)
        } else {
          Label("Assign to me", systemImage: "person.crop.circle.badge.checkmark")
        }
      }
      .keyboardShortcut("a", modifiers: [])
      .disabled(isAssigning || ticket.assignedToMe)
      .help("Assign this ticket to you in Linear (A)")

      if let urlString = ticket.url, let url = URL(string: urlString) {
        Button {
          openInLinear(webURL: url)
        } label: {
          Label("Open in Linear", systemImage: "arrow.up.right.square")
        }
        .keyboardShortcut("o", modifiers: [])
        .help("Open the ticket in the Linear desktop app (O)")
      }

      Spacer()

      // Destructive stays mouse-only — no keyboard shortcut, matching the
      // list row's hover controls.
      Button(role: .destructive) {
        onRemove()
      } label: {
        Label("Remove", systemImage: "trash")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Remove this ticket from the inbox")
    }
    .padding()
  }

  /// Fuller, spelled-out sibling of the list row's `compactAge` — the focus
  /// card has room for "open 4 hours" instead of a terse "4h".
  private func spelledOutAge(since created: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(created))
    let minute = 60.0, hour = 3_600.0, day = 86_400.0, week = 7 * day, month = 30 * day, year = 365 * day
    func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s")" }
    switch seconds {
    case ..<minute: return "just now"
    case ..<hour: return plural(Int(seconds / minute), "minute")
    case ..<day: return plural(Int(seconds / hour), "hour")
    case ..<week: return plural(Int(seconds / day), "day")
    case ..<month: return plural(Int(seconds / week), "week")
    case ..<year: return plural(Int(seconds / month), "month")
    default: return plural(Int(seconds / year), "year")
    }
  }
}

/// Shown once the user has cycled through every card in the focus deck.
/// "Back" stays available so a user who overshot can still step back in.
private struct FocusDeckFinishedCard: View {
  let onRestart: () -> Void
  let onRetreat: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("All caught up", systemImage: "checkmark.seal")
    } description: {
      Text("You've cycled through every ticket matching the filters.")
    } actions: {
      Button("Back") {
        onRetreat()
      }
      .keyboardShortcut(.leftArrow, modifiers: [])
      .help("Back to the previous ticket (←)")

      Button("Start over") {
        onRestart()
      }
      .keyboardShortcut(.defaultAction)
      .help("Restart the deck from the first ticket")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
