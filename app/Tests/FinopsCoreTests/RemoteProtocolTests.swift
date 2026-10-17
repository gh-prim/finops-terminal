import Foundation
import Testing
@testable import FinopsRemote

struct RemoteProtocolTests {
    @Test(arguments: [
        RemoteMessage.pair(code: "123456", deviceID: "d1", deviceName: "iPad"),
        .auth(token: "tok", deviceID: "d1"),
        .command("AAPL US EQ CHART 5Y"),
        .action(.layout4),
        .paired(token: "tok", macName: "Mac"),
        .authOK(macName: "Mac"),
        .authFailed(reason: "nope"),
        .state(RemoteState(macName: "Mac", panels: [RemotePanel(security: "AAPL US EQ", function: "CHART", linked: true)],
                           activePanel: 0, layout: 1, watchlistName: "Main", watchlist: ["SPX IDX"], message: nil)),
    ])
    func roundTrips(_ message: RemoteMessage) {
        let data = message.encoded()
        #expect(RemoteMessage.isRemote(data))
        #expect(RemoteMessage(data) == message)
    }

    @Test func dataProtocolMessagesAreNotRemote() {
        let request = Data(#"{"t":"request","cid":"1","service":"refdata","params":{}}"#.utf8)
        #expect(!RemoteMessage.isRemote(request))
        #expect(RemoteMessage(request) == nil)
    }

    @Test func pairingCodeExpiresAndLocksOut() {
        var code = PairingCode.generate(now: Date(timeIntervalSince1970: 0))
        #expect(code.code.count == 6)
        #expect(code.isValid(at: Date(timeIntervalSince1970: 10)))
        #expect(!code.isValid(at: Date(timeIntervalSince1970: PairingCode.lifetime + 1)))
        code.failedAttempts = PairingCode.maxAttempts
        #expect(!code.isValid(at: Date(timeIntervalSince1970: 10)))
    }

    @Test func tokenHashMatching() {
        let token = PairingCrypto.newToken()
        let hash = PairingCrypto.hash(token)
        #expect(PairingCrypto.matches(token, hash: hash))
        #expect(!PairingCrypto.matches(token + "x", hash: hash))
        #expect(PairingCrypto.newToken() != token)
    }
}
