// MentionParserTests.swift
// PoolChatTests

import XCTest
@testable import PoolChat

final class MentionParserTests: XCTestCase {

    func testExtractMentionUsernames() {
        let usernames = MentionParser.extractMentionUsernames(from: "Hey @alice and @bob_smith!")
        XCTAssertEqual(usernames, ["alice", "bob_smith"])
    }

    func testExtractNoMentions() {
        let usernames = MentionParser.extractMentionUsernames(from: "No mentions here")
        XCTAssertTrue(usernames.isEmpty)
    }

    func testFindMentionedPeerIDs() {
        let peers: [(id: String, displayName: String)] = [
            (id: "id-alice", displayName: "Alice"),
            (id: "id-bob", displayName: "Bob Smith"),
        ]
        let ids = MentionParser.findMentionedPeerIDs(text: "Hey @alice and @Bob_Smith", availablePeers: peers)
        XCTAssertTrue(ids.contains("id-alice"))
        XCTAssertTrue(ids.contains("id-bob"))
    }

    func testGetActiveMentionQuery() {
        XCTAssertEqual(MentionParser.getActiveMentionQuery(from: "Hey @ali"), "ali")
        XCTAssertNil(MentionParser.getActiveMentionQuery(from: "Hey @alice done"))
        XCTAssertEqual(MentionParser.getActiveMentionQuery(from: "@"), "")
    }

    func testReplaceMentionQuery() {
        let result = MentionParser.replaceMentionQuery(in: "Hey @al", with: "Alice")
        XCTAssertEqual(result, "Hey @Alice ")
    }
}
