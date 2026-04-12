import ComposableArchitecture
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        Picker("Mode", selection: $store.mode) {
          Text("Directory").tag(WorkspaceMode.directory)
          Text("New Worktree").tag(WorkspaceMode.newWorktree)
          Text("Existing Worktree").tag(WorkspaceMode.existingWorktree)
        }
        .pickerStyle(.segmented)
      } header: {
        Text("New Workspace")
        Text(headerSubtitle)
      }
      .headerProminence(.increased)

      switch store.mode {
      case .directory:
        Section {
          LabeledContent("Path") {
            Text(store.repositoryRootURL.path(percentEncoded: false))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        } footer: {
          Text("Opens the repository root as a workspace without creating a git worktree.")
            .foregroundStyle(.secondary)
        }

      case .newWorktree:
        Section {
          TextField("Branch name", text: $store.branchName)
            .focused($isBranchFieldFocused)
            .onSubmit {
              store.send(.createButtonTapped)
            }
        }

        Section {
          Picker(selection: $store.selectedBaseRef) {
            automaticRefLabel
              .tag(Optional<String>.none)
            ForEach(store.baseRefOptions, id: \.self) { ref in
              Text(ref)
                .tag(Optional(ref))
            }
          } label: {
            Text("Base ref")
            Text("The branch or ref the new worktree will be created from.")
          }

          Toggle(isOn: $store.fetchOrigin) {
            Text("Fetch remote branch")
            Text(
              "Runs `git fetch` to ensure the base branch is up to date before creating the worktree."
            )
          }
        } footer: {
          if let validationMessage = store.validationMessage, !validationMessage.isEmpty {
            Text(validationMessage)
              .foregroundStyle(.red)
          }
        }

      case .existingWorktree:
        Section {
          if selectableWorktrees.isEmpty {
            Text("No additional worktrees found for this repository.")
              .foregroundStyle(.secondary)
          } else {
            Picker(selection: $store.selectedExistingWorktreeID) {
              Text("Select a worktree…")
                .foregroundStyle(.secondary)
                .tag(Optional<Worktree.ID>.none)
              ForEach(selectableWorktrees, id: \.id) { worktree in
                Text(worktreeLabel(worktree))
                  .tag(Optional(worktree.id))
              }
            } label: {
              Text("Worktree")
              Text("Open an existing worktree as a workspace.")
            }
          }
        } footer: {
          if let validationMessage = store.validationMessage, !validationMessage.isEmpty {
            Text(validationMessage)
              .foregroundStyle(.red)
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .background {
      modeShortcuts
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button(submitButtonTitle) {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("\(submitButtonTitle) (↩)")
        .disabled(store.isValidating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .onChange(of: store.mode) { _, newMode in
      if newMode == .newWorktree {
        isBranchFieldFocused = true
      }
    }
  }

  private var modeShortcuts: some View {
    Group {
      Button("") { store.mode = .directory }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { store.mode = .newWorktree }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
      Button("") { store.mode = .existingWorktree }
        .keyboardShortcut("3", modifiers: .command)
        .hidden()
    }
  }

  private var headerSubtitle: String {
    switch store.mode {
    case .directory:
      "Open `\(store.repositoryName)` as a workspace."
    case .newWorktree:
      "Create a new branch in `\(store.repositoryName)`."
    case .existingWorktree:
      "Check out an existing branch in `\(store.repositoryName)`."
    }
  }

  private var submitButtonTitle: String {
    switch store.mode {
    case .directory: "Open"
    case .newWorktree: "Create"
    case .existingWorktree: "Create"
    }
  }

  private var automaticRefLabel: Text {
    let ref = store.automaticBaseRef
    guard !ref.isEmpty else { return Text("Auto") }
    return Text("Auto \(Text(ref).foregroundStyle(.secondary))")
  }

  private var selectableWorktrees: [Worktree] {
    store.availableWorktrees.filter {
      $0.workingDirectory.standardizedFileURL != store.repositoryRootURL.standardizedFileURL
    }
  }

  private func worktreeLabel(_ worktree: Worktree) -> String {
    if let branch = worktree.branch, !branch.isEmpty {
      branch
    } else {
      worktree.name
    }
  }
}
