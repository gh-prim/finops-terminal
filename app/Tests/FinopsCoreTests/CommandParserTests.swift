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

struct CommandParserExtendedTests {
    @Test func watchAddsLoadedOrNamedSecurity() {
        #expect(CommandParser.parse("nvda us eq watch") == .watch(security: "NVDA US EQ"))
        #expect(CommandParser.parse("WATCH") == .watch(security: nil))
    }

    @Test func screenerFiltersStayArgs() {
        #expect(CommandParser.parse("scrn mcap>10b pe<20")
            == .run(security: nil, function: .scrn, args: ["MCAP>10B", "PE<20"]))
    }

    @Test func aliasesAreUnique() {
        let all = FunctionID.allCases.flatMap(\.aliases)
        #expect(Set(all).count == all.count)
    }
}

struct TVCommandTests {
    @Test func tvKeepsVideoIdCase() {
        #expect(CommandParser.parse("tv QB5BNdBFujE") == .run(security: nil, function: .tv, args: ["QB5BNdBFujE"]))
        #expect(CommandParser.parse("read https://decrypt.co/381246/Bitcoin-ETFs")
                == .run(security: nil, function: .read, args: ["https://decrypt.co/381246/Bitcoin-ETFs"]))
        #expect(CommandParser.parse("ETF top") == .run(security: nil, function: .etf, args: ["TOP"]))
        #expect(CommandParser.parse("crypto eur") == .run(security: nil, function: .crypto, args: ["EUR"]))
        #expect(CommandParser.parse("btc crypto") == .run(security: "BTC CRYPTO", function: .crypto, args: []))
        #expect(CommandParser.parse("BTC CRYPTO CHART 1D 15MIN")
                == .run(security: "BTC CRYPTO", function: .chart, args: ["1D", "15MIN"]))
        #expect(CommandParser.parse("eth eur crypto q") == .run(security: "ETH EUR CRYPTO", function: .quote, args: []))
    }
}

@Test func etfListCommandsKeepTheirList() {
    #expect(CommandParser.parse("ETF PEA") == .run(security: nil, function: .etf, args: ["PEA"]))
    #expect(CommandParser.parse("ETF EUROPE") == .run(security: nil, function: .etf, args: ["EUROPE"]))
}
