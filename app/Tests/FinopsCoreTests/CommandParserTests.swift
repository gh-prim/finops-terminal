import Testing
@testable import FinopsCore

struct CommandParserTests {
    @Test func securityThenFunctionThenArgs() {
        #expect(CommandParser.parse("aapl us eq chart 5y")
            == .run(security: "AAPL US EQ", function: .chart, args: ["5Y"]))
    }

    @Test func functionOnlyKeepsLoadedSecurity() {
        #expect(CommandParser.parse("CHART 1M") == .run(security: nil, function: .chart, args: ["1M"]))
    }

    @Test func securityOnly() {
        #expect(CommandParser.parse("EURUSD FX") == .run(security: "EURUSD FX", function: nil, args: []))
    }

    @Test func aliases() {
        #expect(CommandParser.parse("msft q") == .run(security: "MSFT", function: .quote, args: []))
        #expect(CommandParser.parse("?") == .run(security: nil, function: .help, args: []))
    }

    @Test func numberedAction() {
        #expect(CommandParser.parse(" 3 ") == .action(3))
        #expect(CommandParser.parse("0") == .run(security: "0", function: nil, args: []))
    }

    @Test func empty() {
        #expect(CommandParser.parse("   ") == .empty)
    }
}
