import ComposableArchitecture
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        Picker("Mode", selection: $store.mode) {
          Text("Worktree").tag(WorkspaceMode.worktree)
          Text("Directory").tag(WorkspaceMode.directory)
        }
        .pickerStyle(.segmented)
      } header: {
        Text("New Workspace")
        Text(headerSubtitle)
      }
      .headerProminence(.increased)

      if store.mode == .worktree {
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
      } else {
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
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
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
        Button(store.mode == .worktree ? "Create" : "Open") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help(store.mode == .worktree ? "Create (↩)" : "Open (↩)")
        .disabled(store.isValidating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task {
      if store.mode == .worktree {
        isBranchFieldFocused = true
      }
    }
  }

  private var headerSubtitle: String {
    switch store.mode {
    case .worktree:
      "Create a branch in `\(store.repositoryName)`."
    case .directory:
      "Open `\(store.repositoryName)` as a workspace."
    }
  }

  private var automaticRefLabel: Text {
    let ref = store.automaticBaseRef
    guard !ref.isEmpty else { return Text("Auto") }
    return Text("Auto \(Text(ref).foregroundStyle(.secondary))")
  }
}
