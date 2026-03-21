// PollDataTests.swift
// PoolChatTests

import XCTest
@testable import PoolChat

final class PollDataTests: XCTestCase {

    func testInitializesVotesForAllOptions() {
        let poll = PollData(question: "Q?", options: ["A", "B", "C"])
        XCTAssertEqual(poll.votes.count, 3)
        XCTAssertEqual(poll.votes["A"], [])
        XCTAssertEqual(poll.votes["B"], [])
        XCTAssertEqual(poll.votes["C"], [])
    }

    func testTotalVotes() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": ["p1", "p2"], "B": ["p3"]])
        XCTAssertEqual(poll.totalVotes, 3)
    }

    func testVotePercentage() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": ["p1", "p2"], "B": ["p1"]])
        let pctA = poll.votePercentage(for: "A")
        XCTAssertEqual(pctA, 2.0 / 3.0, accuracy: 0.001)
    }

    func testVotePercentageZeroWhenNoVotes() {
        let poll = PollData(question: "Q?", options: ["A"])
        XCTAssertEqual(poll.votePercentage(for: "A"), 0.0)
    }

    func testHasVotedForSpecificOption() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": ["peer-1"], "B": []])
        XCTAssertTrue(poll.hasVoted(peerID: "peer-1", for: "A"))
        XCTAssertFalse(poll.hasVoted(peerID: "peer-1", for: "B"))
    }

    func testHasVotedAny() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": ["peer-1"], "B": []])
        XCTAssertTrue(poll.hasVoted(peerID: "peer-1"))
        XCTAssertFalse(poll.hasVoted(peerID: "peer-2"))
    }

    func testVotedOption() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": [], "B": ["peer-1"]])
        XCTAssertEqual(poll.votedOption(for: "peer-1"), "B")
        XCTAssertNil(poll.votedOption(for: "peer-2"))
    }

    func testCanVoteNeverVoted() {
        let poll = PollData(question: "Q?", options: ["A"], allowVoteChange: false)
        XCTAssertTrue(poll.canVote(peerID: "new-peer"))
    }

    func testCanVoteAlreadyVotedWithChangeAllowed() {
        let poll = PollData(question: "Q?", options: ["A"], votes: ["A": ["peer-1"]], allowVoteChange: true)
        XCTAssertTrue(poll.canVote(peerID: "peer-1"))
    }

    func testCanVoteAlreadyVotedWithChangeDisallowed() {
        let poll = PollData(question: "Q?", options: ["A"], votes: ["A": ["peer-1"]], allowVoteChange: false)
        XCTAssertFalse(poll.canVote(peerID: "peer-1"))
    }

    func testWithVoteAddsVote() {
        let poll = PollData(question: "Q?", options: ["A", "B"])
        let updated = poll.withVote(from: "peer-1", for: "A")
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.voteCount(for: "A"), 1)
    }

    func testWithVoteReturnsNilWhenChangeDisallowed() {
        let poll = PollData(question: "Q?", options: ["A", "B"], votes: ["A": ["peer-1"], "B": []], allowVoteChange: false)
        let updated = poll.withVote(from: "peer-1", for: "B")
        XCTAssertNil(updated)
    }

    func testPollDataCodable() throws {
        let original = PollData(question: "Lunch?", options: ["Pizza", "Sushi"], votes: ["Pizza": ["p1"], "Sushi": []], allowVoteChange: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PollData.self, from: data)
        XCTAssertEqual(decoded.question, "Lunch?")
        XCTAssertEqual(decoded.options, ["Pizza", "Sushi"])
        XCTAssertEqual(decoded.voteCount(for: "Pizza"), 1)
        XCTAssertTrue(decoded.allowVoteChange)
    }
}
