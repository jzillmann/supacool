import Foundation

enum GitWorktreeHeadResolver {
  static func headURL(for worktreeURL: URL, fileManager: FileManager) -> URL? {
    var candidate = worktreeURL.standardizedFileURL
    while true {
      if let headURL = directHeadURL(at: candidate, fileManager: fileManager) {
        return headURL
      }
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      if parent.path(percentEncoded: false) == candidate.path(percentEncoded: false) {
        return nil
      }
      candidate = parent
    }
  }

  private static func directHeadURL(at directoryURL: URL, fileManager: FileManager) -> URL? {
    let gitURL = directoryURL.appending(path: ".git")
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(
        atPath: gitURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    else {
      return nil
    }
    if isDirectory.boolValue {
      return gitURL.appending(path: "HEAD")
    }
    guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else {
      return nil
    }
    guard let line = contents.split(whereSeparator: \.isNewline).first else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "gitdir:"
    guard trimmed.hasPrefix(prefix) else {
      return nil
    }
    let pathPart = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathPart.isEmpty else {
      return nil
    }
    let gitdirURL = URL(fileURLWithPath: String(pathPart), relativeTo: directoryURL)
      .standardizedFileURL
    return gitdirURL.appending(path: "HEAD")
  }
}
