import Testing
@testable import AgentGrid

struct TerminalResourcePolicyTests {
    @Test("each terminal keeps bounded text and inline-image history")
    func optionsAreExplicitlyBounded() {
        let options = TerminalResourcePolicy.options

        #expect(options.scrollback == 500)
        #expect(options.kittyImageCacheLimitBytes == 32 * 1_024 * 1_024)
        #expect(options.kittyImageTransferLimitBytes == 8 * 1_024 * 1_024)
    }

    @Test("inline-image cache stays bounded across realistic pane counts", arguments: [1, 4, 12])
    func aggregateInlineImageCacheIsBounded(paneCount: Int) {
        let totalBytes = TerminalResourcePolicy.inlineImageCacheBytesPerPane * paneCount

        #expect(totalBytes <= 384 * 1_024 * 1_024)
    }

    @MainActor
    @Test("the application's maximum grid count has a hard aggregate image-cache ceiling")
    func maximumGridCountHasBoundedCache() {
        let maximumPaneCount = GridTabsModel.maximumCount * 4
        let totalBytes = TerminalResourcePolicy.inlineImageCacheBytesPerPane * maximumPaneCount

        #expect(totalBytes <= 768 * 1_024 * 1_024)
    }
}
