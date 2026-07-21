import Foundation
import Testing

@testable import SessionNest

@Suite("QuotaUsageHistoryTests")
struct QuotaUsageHistoryTests {
    @Test func firstSampleIsBaselineAndSameDayPositiveDeltasAccumulate() {
        let calendar = calendar(timeZone: "UTC")
        let start = timestamp(2026, 7, 20, hour: 10, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: start, usedPercent: 10),
                sample(at: start + 5 * 60, usedPercent: 15),
                sample(at: start + 10 * 60, usedPercent: 21),
            ],
            cycleResetsAt: cycleResetsAt,
            now: start + 10 * 60,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(dayStart: dayStart(start, calendar: calendar), usedPercent: 11)
            ])
    }

    @Test func midnightDeltaBelongsToLaterSamplesLocalDay() {
        let calendar = calendar(timeZone: "America/Los_Angeles")
        let beforeMidnight = timestamp(2026, 7, 20, hour: 23, minute: 55, calendar: calendar)
        let afterMidnight = timestamp(2026, 7, 21, hour: 0, minute: 5, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: beforeMidnight, usedPercent: 40),
                sample(at: afterMidnight, usedPercent: 47),
            ],
            cycleResetsAt: cycleResetsAt,
            now: afterMidnight,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(
                    dayStart: dayStart(afterMidnight, calendar: calendar), usedPercent: 7)
            ])
    }

    @Test func decreaseBecomesBaselineForLaterPositiveDelta() {
        let calendar = calendar(timeZone: "UTC")
        let start = timestamp(2026, 7, 20, hour: 10, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: start, usedPercent: 40),
                sample(at: start + 5 * 60, usedPercent: 55),
                sample(at: start + 10 * 60, usedPercent: 20),
                sample(at: start + 15 * 60, usedPercent: 29),
            ],
            cycleResetsAt: cycleResetsAt,
            now: start + 15 * 60,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(dayStart: dayStart(start, calendar: calendar), usedPercent: 24)
            ])
    }

    @Test func gapsOverMaximumDoNotAddUsageButLaterSampleBecomesBaseline() {
        let calendar = calendar(timeZone: "UTC")
        let start = timestamp(2026, 7, 20, hour: 10, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: start, usedPercent: 10),
                sample(at: start + QuotaDailyUsage.maximumGap + 1, usedPercent: 50),
                sample(at: start + QuotaDailyUsage.maximumGap + 1 + 5 * 60, usedPercent: 56),
            ],
            cycleResetsAt: cycleResetsAt,
            now: start + QuotaDailyUsage.maximumGap + 1 + 5 * 60,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(dayStart: dayStart(start, calendar: calendar), usedPercent: 6)
            ])
    }

    @Test func excludesOtherCyclesFutureAndNonFiniteSamples() {
        let calendar = calendar(timeZone: "UTC")
        let start = timestamp(2026, 7, 20, hour: 10, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: start, usedPercent: 10),
                QuotaUsageSample(
                    cycleResetsAt: cycleResetsAt - 1, capturedAt: start + 10, usedPercent: 99),
                sample(at: start + 20, usedPercent: .nan),
                sample(at: start + 70, usedPercent: 20),
                sample(at: start + 80, usedPercent: 100),
            ],
            cycleResetsAt: cycleResetsAt,
            now: start + 70,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(dayStart: dayStart(start, calendar: calendar), usedPercent: 10)
            ])
    }

    @Test func dailyUsageIsClampedToOneHundredPercent() {
        let calendar = calendar(timeZone: "UTC")
        let start = timestamp(2026, 7, 20, hour: 10, calendar: calendar)

        let points = QuotaDailyUsage.build(
            samples: [
                sample(at: start, usedPercent: 0),
                sample(at: start + 5 * 60, usedPercent: 60),
                sample(at: start + 10 * 60, usedPercent: 130),
            ],
            cycleResetsAt: cycleResetsAt,
            now: start + 10 * 60,
            calendar: calendar
        )

        #expect(
            points == [
                QuotaDailyUsagePoint(
                    dayStart: dayStart(start, calendar: calendar), usedPercent: 100)
            ])
    }

    @Test func retainsOnlyTheMostRecentSevenLocalDates() {
        let calendar = calendar(timeZone: "Asia/Shanghai")
        let now = timestamp(2026, 7, 21, hour: 12, calendar: calendar)
        let samples = (14...21).flatMap { day in
            let baseline = timestamp(2026, 7, day, hour: 10, calendar: calendar)
            return [
                sample(at: baseline, usedPercent: 0),
                sample(at: baseline + 5 * 60, usedPercent: 10),
            ]
        }

        let points = QuotaDailyUsage.build(
            samples: samples,
            cycleResetsAt: cycleResetsAt,
            now: now,
            calendar: calendar
        )

        #expect(
            points
                == (15...21).map { day in
                    QuotaDailyUsagePoint(
                        dayStart: timestamp(2026, 7, day, calendar: calendar),
                        usedPercent: 10
                    )
                })
    }

    private let cycleResetsAt: Int64 = 1_784_160_000

    private func sample(at capturedAt: Int64, usedPercent: Double) -> QuotaUsageSample {
        QuotaUsageSample(
            cycleResetsAt: cycleResetsAt,
            capturedAt: capturedAt,
            usedPercent: usedPercent
        )
    }

    private func calendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func dayStart(_ timestamp: Int64, calendar: Calendar) -> Int64 {
        Int64(
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
                .timeIntervalSince1970)
    }

    private func timestamp(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        calendar: Calendar
    ) -> Int64 {
        Int64(
            calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                ))!.timeIntervalSince1970)
    }
}
