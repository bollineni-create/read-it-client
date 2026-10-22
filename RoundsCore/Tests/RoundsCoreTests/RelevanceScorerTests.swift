import XCTest
@testable import RoundsCore

final class RelevanceScorerTests: XCTestCase {
    let stats = SubredditStats(maxScore: 1000, maxComments: 500)

    func input(score: Int = 0, comments: Int = 0, depth: Int = 0, links: Int = 0,
               title: String = "A post", body: String = "", commentBodies: [String] = []) -> ScoringInput {
        ScoringInput(subName: "mdphd", window: .month, score: score, numComments: comments, maxReplyDepth: depth,
                     uniqueLinkCount: links, title: title, body: body, commentBodies: commentBodies)
    }

    func testScoreIsBoundedZeroToHundred() {
        let top = RelevanceScorer.score(input(score: 1000, comments: 500, depth: 9, links: 10, title: "MSTP interviews"),
                                        stats: stats, weights: .default, keywords: ["MSTP", "interviews"])
        XCTAssertLessThanOrEqual(top.relevance, 100)
        XCTAssertGreaterThan(top.relevance, 95)

        let nothing = RelevanceScorer.score(input(), stats: stats, weights: .default, keywords: ["MSTP"])
        XCTAssertEqual(nothing.relevance, 0)
    }

    func testUpvotesAreLogScaledWithinSubreddit() {
        let half = RelevanceScorer.logNormalized(500, max: 1000)
        XCTAssertGreaterThan(half, 0.85, "log scaling keeps a 500-upvote post close to the 1000-upvote max")
        XCTAssertEqual(RelevanceScorer.logNormalized(1000, max: 1000), 1, accuracy: 1e-9)
        XCTAssertEqual(RelevanceScorer.logNormalized(0, max: 1000), 0)
        XCTAssertEqual(RelevanceScorer.logNormalized(10, max: 0), 1, accuracy: 1e-9, "max never falls below the value itself")
    }

    func testWeightsChangeRanking() {
        let popular = input(score: 1000, comments: 10)
        let linky = input(score: 50, comments: 10, links: 4)
        let upvoteHeavy = RelevanceWeights(upvotes: 1, discussion: 0, resources: 0, keywords: 0)
        let resourceHeavy = RelevanceWeights(upvotes: 0, discussion: 0, resources: 1, keywords: 0)

        XCTAssertGreaterThan(RelevanceScorer.score(popular, stats: stats, weights: upvoteHeavy, keywords: []).relevance,
                             RelevanceScorer.score(linky, stats: stats, weights: upvoteHeavy, keywords: []).relevance)
        XCTAssertGreaterThan(RelevanceScorer.score(linky, stats: stats, weights: resourceHeavy, keywords: []).relevance,
                             RelevanceScorer.score(popular, stats: stats, weights: resourceHeavy, keywords: []).relevance)
        XCTAssertEqual(RelevanceScorer.score(popular, stats: stats, weights: RelevanceWeights(upvotes: 0, discussion: 0, resources: 0, keywords: 0), keywords: []).relevance, 0)
    }

    func testDiscussionUsesCommentsAndDepth() {
        let shallow = RelevanceScorer.score(input(comments: 100, depth: 0), stats: stats, weights: .default, keywords: [])
        let deep = RelevanceScorer.score(input(comments: 100, depth: 5), stats: stats, weights: .default, keywords: [])
        XCTAssertGreaterThan(deep.discussionSignal, shallow.discussionSignal)
        XCTAssertEqual(deep.discussionSignal - shallow.discussionSignal, 0.3, accuracy: 1e-9)
    }

    func testKeywordMatchingIsWholeWordAndCaseInsensitive() {
        let matched = RelevanceScorer.matchKeywords(["MSTP", "interviews", "MD", "step 1"],
                                                    in: ["mstp Interviews this cycle", "made it! Step 1 done"])
        XCTAssertEqual(matched, ["MSTP", "interviews", "step 1"], "\"MD\" must not match inside \"made\"")
        XCTAssertEqual(RelevanceScorer.matchKeywords(["C++"], in: ["I like C++ a lot"]), ["C++"])
    }

    func testKeywordsAreCheckedAgainstCommentsToo() {
        let result = RelevanceScorer.score(input(commentBodies: ["My MSTP interview went well"]),
                                           stats: stats, weights: .default, keywords: ["MSTP"])
        XCTAssertEqual(result.matchedKeywords, ["MSTP"])
        XCTAssertEqual(result.keywordSignal, 0.6, accuracy: 1e-9)
    }

    func testWhyStringNamesTheStrongestSignalAndMatches() {
        let discussion = RelevanceScorer.score(
            input(score: 100, comments: 500, depth: 5, title: "MSTP interviews thread"),
            stats: stats, weights: RelevanceWeights(upvotes: 0.2, discussion: 0.6, resources: 0.1, keywords: 0.1),
            keywords: ["MSTP", "interviews"]
        )
        XCTAssertTrue(discussion.why.hasPrefix("Top discussion in r/mdphd this month"), discussion.why)
        XCTAssertTrue(discussion.why.hasSuffix("matches: MSTP, interviews"), discussion.why)

        let upvoted = RelevanceScorer.score(input(score: 1000), stats: stats, weights: .default, keywords: [])
        XCTAssertEqual(upvoted.why, "Top post in r/mdphd this month")

        let linky = RelevanceScorer.score(input(score: 1, links: 3), stats: stats,
                                          weights: RelevanceWeights(upvotes: 0.1, discussion: 0.1, resources: 1, keywords: 0), keywords: [])
        XCTAssertTrue(linky.why.hasPrefix("Shares 3 resources in r/mdphd"), linky.why)
    }
}
