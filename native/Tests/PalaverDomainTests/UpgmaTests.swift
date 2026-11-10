// UPGMA as people.py's `_groups` runs it through scipy: `linkage(X, "average", metric="cosine")` and
// `fcluster(Z, t, criterion="distance")`, ties included (golden `upgma`, written by scipy 1.17).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct UpgmaTests {
    private func vectors(_ v: JSONValue?) throws -> [[Double]] {
        try #require(v?.arrayValue).map { row in try #require(row.arrayValue).map { try #require($0.doubleValue) } }
    }

    @Test func theLinkageIsScipysTiesIncluded() throws {
        let cases = try #require(Goldens.load("upgma")["cases"]?.arrayValue)
        #expect(cases.count == 12)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let z = try Upgma.linkage(try vectors(c["vectors"]))
            let got = JSONValue.array(z.map { .array([.int($0.a), .int($0.b), .double(Py.round($0.distance, 12)), .int($0.size)]) })
            #expect(PythonJSON.dumps(got) == PythonJSON.dumps(c["z"] ?? .null), "linkage of \(name)")
        }
    }

    @Test func theFlatClustersAreScipysAtEveryCut() throws {
        let cases = try #require(Goldens.load("upgma")["cases"]?.arrayValue)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let input = try vectors(c["vectors"])
            for cut in try #require(c["clusters"]?.arrayValue) {
                let t = try #require(cut.arrayValue?[0].doubleValue)
                let got = JSONValue.array(try Upgma.fcluster(input, threshold: t).map { .int($0) })
                #expect(PythonJSON.dumps(got) == PythonJSON.dumps(cut.arrayValue?[1] ?? .null), "fcluster of \(name) at \(t)")
            }
        }
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

    @Test func aZeroVectorOrTwoLengthsAreErrorsAsInScipy() {
        #expect(throws: UpgmaError.self) { try Upgma.fcluster([[1, 0], [0, 0]], threshold: 0.25) }
        #expect(throws: UpgmaError.self) { try Upgma.fcluster([[1, 0], [0, 1, 0]], threshold: 0.25) }
        #expect(throws: UpgmaError.self) { try Upgma.fcluster([[1, .nan], [0, 1]], threshold: 0.25) }
    }
}
