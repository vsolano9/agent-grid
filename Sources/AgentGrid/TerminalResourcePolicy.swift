import SwiftTerm

enum TerminalResourcePolicy {
    static let scrollbackLines = 500
    static let inlineImageCacheBytesPerPane = 32 * 1_024 * 1_024
    static let inlineImageTransferBytesPerPane = 8 * 1_024 * 1_024

    static var options: TerminalOptions {
        var options = TerminalOptions.default
        options.scrollback = scrollbackLines
        options.kittyImageCacheLimitBytes = inlineImageCacheBytesPerPane
        options.kittyImageTransferLimitBytes = inlineImageTransferBytesPerPane
        return options
    }
}
