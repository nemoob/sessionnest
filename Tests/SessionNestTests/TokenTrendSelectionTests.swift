import Testing

@testable import SessionNest

@Suite("TokenTrendSelectionTests")
struct TokenTrendSelectionTests {
    @Test func nearestPointClampsOutsideRangeAndChoosesEarlierTie() {
        let points = [point(100), point(200), point(300)]

        #expect(TokenTrendSelection.nearestPoint(to: 10, in: points)?.dayStart == 100)
        #expect(TokenTrendSelection.nearestPoint(to: 390, in: points)?.dayStart == 300)
        #expect(TokenTrendSelection.nearestPoint(to: 150, in: points)?.dayStart == 100)
        #expect(TokenTrendSelection.nearestPoint(to: 151, in: points)?.dayStart == 200)
    }

    @Test func nearestPointHandlesEmptyAndSinglePointData() {
        #expect(TokenTrendSelection.nearestPoint(to: 100, in: []) == nil)
        #expect(
            TokenTrendSelection.nearestPoint(to: 9_999, in: [point(500)])?.dayStart == 500
        )
    }

    @Test func reconcileClearsDatesThatDisappear() {
        let points = [point(100), point(200)]

        #expect(TokenTrendSelection.reconcile(selectedDay: nil, in: points) == nil)
        #expect(TokenTrendSelection.reconcile(selectedDay: 100, in: points) == 100)
        #expect(TokenTrendSelection.reconcile(selectedDay: 300, in: points) == nil)
    }

    @Test func adjacentPointMovesWithinBounds() {
        let points = [point(100), point(200), point(300)]

        #expect(
            TokenTrendSelection.adjacentPoint(
                from: nil,
                direction: .next,
                in: points
            )?.dayStart == 100
        )
        #expect(
            TokenTrendSelection.adjacentPoint(
                from: 200,
                direction: .previous,
                in: points
            )?.dayStart == 100
        )
        #expect(
            TokenTrendSelection.adjacentPoint(
                from: 200,
                direction: .next,
                in: points
            )?.dayStart == 300
        )
        #expect(
            TokenTrendSelection.adjacentPoint(
                from: 300,
                direction: .next,
                in: points
            )?.dayStart == 300
        )
    }

    private func point(_ dayStart: Int64) -> StatisticsDailyPoint {
        StatisticsDailyPoint(dayStart: dayStart, usage: .zero)
    }
}
