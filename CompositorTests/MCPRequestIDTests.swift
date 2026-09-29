import Foundation
import Testing
@testable import Compositor

/// `MCPRequestIDs` gives every HTTP request its own JSON-RPC id on the way into the
/// stateless transport and puts the client's id back on the way out, so two clients
/// that both number their requests 1, 2, 3… never collide inside the server.
struct MCPRequestIDTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func integerIDRoundTripsAsAnInteger() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        let rewritten = try #require(MCPRequestIDs.rewrite(body, prefix: "c1/"))
        let sent = try object(rewritten.body)
        let newID = try #require(sent["id"] as? String)
        #expect(newID.hasPrefix("c1/"))
        #expect(sent["method"] as? String == "tools/list")

        let response = Data(#"{"jsonrpc":"2.0","id":"\#(newID)","result":{"tools":[]}}"#.utf8)
        let restored = MCPRequestIDs.restore(response, original: rewritten.original)
        let text = try #require(String(data: restored, encoding: .utf8))
        #expect(text.contains(#""id":1"#), "Integer id must come back as a JSON number: \(text)")
        #expect(try object(restored)["result"] != nil)
    }

    @Test func stringIDRoundTripsAsAString() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":"abc-7","method":"tools/call","params":{"name":"undo"}}"#.utf8)
        let rewritten = try #require(MCPRequestIDs.rewrite(body, prefix: "c2/"))
        let newID = try #require(try object(rewritten.body)["id"] as? String)
        #expect(newID != "abc-7" && newID.hasPrefix("c2/"))

        let response = Data(#"{"jsonrpc":"2.0","id":"\#(newID)","result":{}}"#.utf8)
        let restored = try object(MCPRequestIDs.restore(response, original: rewritten.original))
        #expect(restored["id"] as? String == "abc-7")
    }

    @Test func differentPrefixesGiveTheSameClientIDDifferentServerIDs() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let a = try #require(MCPRequestIDs.rewrite(body, prefix: "a/"))
        let b = try #require(MCPRequestIDs.rewrite(body, prefix: "b/"))
        #expect(try object(a.body)["id"] as? String != object(b.body)["id"] as? String)
    }

    @Test func batchArraysAndNotificationsAreLeftAlone() {
        let batch = Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let garbage = Data("not json".utf8)
        #expect(MCPRequestIDs.rewrite(batch, prefix: "p/") == nil)
        #expect(MCPRequestIDs.rewrite(notification, prefix: "p/") == nil)
        #expect(MCPRequestIDs.rewrite(garbage, prefix: "p/") == nil)
    }

    @Test func aRequestWithAnIDThatIsNeitherStringNorNumberCannotBeIsolated() {
        let body = Data(#"{"jsonrpc":"2.0","id":{"n":1},"method":"ping"}"#.utf8)
        #expect(MCPRequestIDs.rewrite(body, prefix: "p/") == nil)
        guard case .failed = MCPRequestIDs.outcome(of: body, prefix: "p/") else {
            Issue.record("Expected .failed, not a pass-through")
            return
        }
    }

    @Test func notificationsAndBatchesPassThrough() {
        for text in [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#] {
            guard case .passThrough = MCPRequestIDs.outcome(of: Data(text.utf8), prefix: "p/") else {
                Issue.record("Expected .passThrough for \(text)")
                continue
            }
        }
    }

    @Test func restoreLeavesNonObjectResponsesUntouched() {
        let batch = Data(#"[{"jsonrpc":"2.0","id":"x","result":{}}]"#.utf8)
        #expect(MCPRequestIDs.restore(batch, original: 1 as NSNumber) == batch)
    }
}
