#if os(macOS)
import Compression
import Foundation
import Testing

@testable import SwiftTerm

@Suite("Kitty payload allocation limits")
struct KittyPayloadLimitTests {
    @Test("rejects a cumulative multi-chunk payload before appending past the configured limit")
    func rejectsOversizedChunkedPayloadAndClearsPendingState() {
        let terminal = makeTerminal(maximumBytes: 32)

        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=8,i=1,m=1;AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
        #expect(terminal.kittyGraphicsState.pending?.base64Payload.count == 32)

        terminal.handleKittyGraphics(ArraySlice("m=1;AAAAAAAAAAAAAAAA".utf8))
        #expect(terminal.kittyGraphicsState.pending == nil)
        #expect(terminal.kittyGraphicsState.imagesById.isEmpty)

        terminal.handleKittyGraphics(ArraySlice("m=0;AAAA".utf8))
        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=1,i=2,m=0;\(valid)".utf8))
        #expect(terminal.kittyGraphicsState.imagesById[2] != nil)
    }

    @Test("an oversized first chunk drains continuations and recovers after the final chunk")
    func oversizedFirstChunkDrainsThroughFinalChunk() {
        let terminal = makeTerminal(maximumBytes: 16)

        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=8,i=3,m=1;AAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
        terminal.handleKittyGraphics(ArraySlice("m=1;AAAA".utf8))
        #expect(terminal.kittyGraphicsState.pending == nil)
        terminal.handleKittyGraphics(ArraySlice("m=0;AAAA".utf8))

        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=1,i=4,m=0;\(valid)".utf8))
        #expect(terminal.kittyGraphicsState.imagesById[4] != nil)
    }

    @Test("overflow in the final chunk does not discard the next transfer")
    func finalChunkOverflowDoesNotPoisonNextTransfer() {
        let terminal = makeTerminal(maximumBytes: 16)
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=4,i=5,m=1;AAAAAAAAAAAAAAAA".utf8))
        terminal.handleKittyGraphics(ArraySlice("m=0;AAAAAAAAAAAA".utf8))

        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=1,i=6,m=0;\(valid)".utf8))
        #expect(terminal.kittyGraphicsState.imagesById[6] != nil)
    }

    @Test("parser overflow in a final continuation does not discard the next transfer")
    func parserOverflowInFinalContinuationDoesNotPoisonNextTransfer() {
        let terminal = makeTerminal(maximumBytes: 16)
        terminal.feed(text: "\u{1b}_Ga=t,f=24,s=1,v=4,i=50,m=1;AAAAAAAA\u{1b}\\")

        let oversizedFinal = "\u{1b}_Gm=0;" + String(repeating: "A", count: terminal.kittyMaximumAPCBytes) + "\u{1b}\\"
        terminal.feed(text: oversizedFinal)

        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.feed(text: "\u{1b}_Ga=t,f=24,s=1,v=1,i=51,m=0;\(valid)\u{1b}\\")
        #expect(terminal.kittyGraphicsState.imagesById[51] != nil)
    }

    @Test("rejects an oversized single payload before base64 decoding")
    func rejectsOversizedSinglePayloadBeforeDecode() {
        let (terminal, delegate) = makeTerminalAndDelegate(maximumBytes: 32)
        let oversized = Data(repeating: 0x7f, count: 39).base64EncodedString()

        terminal.handleKittyGraphics(ArraySlice("a=q,f=24,s=1,v=13,i=7;\(oversized)".utf8))

        #expect(delegate.sentData.count == 1)
        #expect(String(decoding: delegate.sentData[0], as: UTF8.self).contains("EFBIG"))
        #expect(terminal.kittyGraphicsState.pending == nil)
        #expect(terminal.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test("rejects compressed expansion at the decoded-byte ceiling")
    func rejectsCompressedExpansionAtLimit() throws {
        let (terminal, delegate) = makeTerminalAndDelegate(maximumBytes: 1_024)
        let compressed = try zlibCompressed(Data(repeating: 0, count: 8_192))
        let encoded = compressed.base64EncodedString()
        #expect(encoded.utf8.count < 1_024)

        terminal.handleKittyGraphics(ArraySlice("a=q,f=24,s=1,v=273,i=9,o=z;\(encoded)".utf8))

        #expect(delegate.sentData.count == 1)
        #expect(String(decoding: delegate.sentData[0], as: UTF8.self).contains("EFBIG"))
        #expect(terminal.kittyGraphicsState.pending == nil)
        #expect(terminal.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test("bounds an unterminated Kitty APC before the graphics handler sees it")
    func boundsParserAPCBufferAndRecovers() {
        let (terminal, delegate) = makeTerminalAndDelegate(maximumBytes: 1_024)
        terminal.feed(buffer: ArraySlice("\u{1b}_Ga=q,f=24,s=1,v=1,i=11;".utf8))
        let junk = [UInt8](repeating: UInt8(ascii: "A"), count: 64 * 1_024)
        for sliceStart in stride(from: 0, to: junk.count, by: 4_096) {
            terminal.feed(buffer: junk[sliceStart..<min(sliceStart + 4_096, junk.count)])
            #expect(terminal.parser._apc.count <= terminal.kittyMaximumAPCBytes)
        }

        terminal.feed(text: "\u{1b}\\")
        #expect(delegate.sentData.count == 1)
        #expect(String(decoding: delegate.sentData[0], as: UTF8.self).contains("EFBIG"))
        #expect(terminal.parser._apc.isEmpty)

        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=1,i=12;\(valid)".utf8))
        #expect(terminal.kittyGraphicsState.imagesById[12] != nil)
    }

    @Test("discards every continuation after overflow until the final chunk")
    func discardsOversizedTransferContinuationsUntilFinalChunk() {
        let terminal = makeTerminal(maximumBytes: 32)
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=8,i=20,m=1;AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
        terminal.handleKittyGraphics(ArraySlice("m=1;AAAAAAAAAAAAAAAA".utf8))

        terminal.handleKittyGraphics(ArraySlice("m=1;AAAA".utf8))
        #expect(terminal.kittyGraphicsState.pending == nil)
        terminal.handleKittyGraphics(ArraySlice("m=0;AAAA".utf8))
        #expect(terminal.kittyGraphicsState.pending == nil)

        let valid = Data(repeating: 0x7f, count: 3).base64EncodedString()
        terminal.handleKittyGraphics(ArraySlice("a=t,f=24,s=1,v=1,i=21;\(valid)".utf8))
        #expect(terminal.kittyGraphicsState.imagesById[21] != nil)
    }

    @Test("reports size errors for q=0 and q=1 but suppresses q=2")
    func sizeErrorResponseHonorsQuietLevel() {
        for quietLevel in [0, 1, 2] {
            let (terminal, delegate) = makeTerminalAndDelegate(maximumBytes: 32)
            let oversized = Data(repeating: 0x7f, count: 39).base64EncodedString()
            terminal.handleKittyGraphics(
                ArraySlice("a=q,f=24,s=1,v=13,i=\(30 + quietLevel),q=\(quietLevel);\(oversized)".utf8)
            )
            #expect(delegate.sentData.isEmpty == (quietLevel == 2))
        }
    }

    private func makeTerminal(maximumBytes: Int) -> Terminal {
        makeTerminalAndDelegate(maximumBytes: maximumBytes).terminal
    }

    private func makeTerminalAndDelegate(maximumBytes: Int) -> (
        terminal: Terminal,
        delegate: TerminalTestDelegate
    ) {
        let delegate = TerminalTestDelegate()
        var options = TerminalOptions(cols: 10, rows: 5)
        options.kittyImageCacheLimitBytes = maximumBytes
        options.kittyImageTransferLimitBytes = maximumBytes
        return (Terminal(delegate: delegate, options: options), delegate)
    }

    private func zlibCompressed(_ data: Data) throws -> Data {
        let destinationCapacity = max(64, data.count)
        var destination = [UInt8](repeating: 0, count: destinationCapacity)
        let count = data.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { output in
                compression_encode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { throw CompressionError.failed }
        return Data(destination.prefix(count))
    }

    private enum CompressionError: Error {
        case failed
    }
}
#endif
