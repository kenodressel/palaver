// UPGMA (average linkage over cosine distance) and its flat clusters: the cut and the edge cases.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct UpgmaTests {
    private func vectors(_ v: JSONValue?) throws -> [[Double]] {
        try #require(v?.arrayValue).map { row in try #require(row.arrayValue).map { try #require($0.doubleValue) } }
    }

    @Test func aDistanceOfExactlyTheCutJoins() throws {
        // cos((1,0,0,0,0), (3,2,1,1,1)) is 3/4 exactly: distance 0.25, the people's cut.
        let clusters = try Upgma.fcluster([[1, 0, 0, 0, 0], [3, 2, 1, 1, 1], [0, 0, 0, 0, 1]], threshold: 1 - People.GROUP_THRESHOLD)
        #expect(clusters[0] == clusters[1] && clusters[0] != clusters[2])
    }

    @Test func oneVectorIsOneClusterAndNoneNone() throws {
        #expect(try Upgma.fcluster([[1, 2]], threshold: 0.25) == [1])
        #expect(try Upgma.fcluster([], threshold: 0.25) == [])
    }

}
