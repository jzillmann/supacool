import SwiftUI

struct SkillAutocompletePopover: View {
  let queryText: String
  let skills: [Skill]
  let selectedSkillID: Skill.ID?
  let onSelect: (Skill) -> Void

  var body: some View {
    let userInvocable = Self.matchingSkills(in: skills, queryText: queryText, userInvocable: true)
    let agentOnly = Self.matchingSkills(in: skills, queryText: queryText, userInvocable: false)

    VStack(alignment: .leading, spacing: 10) {
      if userInvocable.isEmpty, agentOnly.isEmpty {
        Text("No matching skills")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
      } else {
        if !userInvocable.isEmpty {
          section(title: "Slash Commands", skills: userInvocable)
        }
        if !agentOnly.isEmpty {
          section(title: "Agent Skills", skills: agentOnly)
        }
      }
    }
    .padding(.vertical, 10)
    .frame(width: 360, alignment: .topLeading)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
  }

  static func orderedMatchingSkills(in skills: [Skill], queryText: String) -> [Skill] {
    matchingSkills(in: skills, queryText: queryText, userInvocable: true)
      + matchingSkills(in: skills, queryText: queryText, userInvocable: false)
  }

  private static func matchingSkills(
    in skills: [Skill],
    queryText: String,
    userInvocable: Bool
  ) -> [Skill] {
    let loweredQuery = queryText.lowercased()
    return skills.filter { skill in
      guard skill.isUserInvocable == userInvocable else { return false }
      guard !loweredQuery.isEmpty else { return true }
      return skill.name.lowercased().hasPrefix(loweredQuery)
    }
  }

  @ViewBuilder
  private func section(title: String, skills: [Skill]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)

      ForEach(skills) { skill in
        Button {
          onSelect(skill)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text(displayName(for: skill))
                .font(.callout.weight(.semibold))
                .monospaced()
                .foregroundStyle(.primary)
              Text(firstDescriptionLine(for: skill))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            sourceTag(for: skill.source)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(selectedSkillID == skill.id ? Color.accentColor.opacity(0.14) : .clear)
          )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
      }
    }
  }

  private func displayName(for skill: Skill) -> String {
    skill.isUserInvocable ? "/\(skill.name)" : skill.name
  }

  private func firstDescriptionLine(for skill: Skill) -> String {
    skill.description
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? skill.description
  }

  private func sourceTag(for source: Skill.Source) -> some View {
    Text(source.rawValue.capitalized)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.secondary.opacity(0.12))
      .clipShape(Capsule())
  }
}
