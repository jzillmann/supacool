import Testing

@testable import Supacool

struct GitignorePatternTests {
  @Test func anchorsPlainPathAtRepoRoot() {
    #expect(GitignorePattern.repoRootAnchoredPattern(for: "tmp/log.txt") == "/tmp/log.txt")
  }

  @Test func escapesWhitespaceAndGlobCharacters() {
    #expect(
      GitignorePattern.repoRootAnchoredPattern(for: "scratch dir/file?.json")
        == "/scratch\\ dir/file\\?.json"
    )
  }

  @Test func preservesDirectorySlash() {
    #expect(GitignorePattern.repoRootAnchoredPattern(for: "cache/") == "/cache/")
  }
}
