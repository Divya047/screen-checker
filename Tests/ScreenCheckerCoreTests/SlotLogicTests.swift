import XCTest
@testable import ScreenCheckerCore

final class SlotLogicTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 9, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: TimeSlot.contains

    func testBasicSlot() {
        let slot = TimeSlot(start: "09:00", end: "17:30")
        XCTAssertTrue(slot.contains(date(hour: 12, minute: 30), calendar: calendar))
        XCTAssertTrue(slot.contains(date(hour: 9, minute: 0), calendar: calendar))   // inclusive start
        XCTAssertFalse(slot.contains(date(hour: 8, minute: 59), calendar: calendar))
        XCTAssertTrue(slot.contains(date(hour: 17, minute: 29), calendar: calendar))
        XCTAssertFalse(slot.contains(date(hour: 17, minute: 30), calendar: calendar)) // exclusive end
    }

    func testSingleDigitHourParsing() {
        let slot = TimeSlot(start: "9:00", end: "12:30")
        XCTAssertTrue(slot.contains(date(hour: 10, minute: 0), calendar: calendar))
        XCTAssertFalse(slot.contains(date(hour: 12, minute: 30), calendar: calendar))
    }

    func testWrapPastMidnight() {
        let slot = TimeSlot(start: "22:00", end: "02:00")
        XCTAssertTrue(slot.contains(date(hour: 23, minute: 0), calendar: calendar))
        XCTAssertTrue(slot.contains(date(hour: 1, minute: 30), calendar: calendar))
        XCTAssertFalse(slot.contains(date(hour: 2, minute: 0), calendar: calendar))
        XCTAssertFalse(slot.contains(date(hour: 21, minute: 59), calendar: calendar))
        XCTAssertFalse(slot.contains(date(hour: 12, minute: 0), calendar: calendar))
    }

    func testInvalidSlotTimesNeverMatch() {
        let slot = TimeSlot(start: "25:00", end: "26:99")
        XCTAssertNil(TimeSlot.minutes(from: "25:00"))
        XCTAssertNil(TimeSlot.minutes(from: "26:99"))
        XCTAssertNil(TimeSlot.minutes(from: "9"))
        XCTAssertNil(TimeSlot.minutes(from: "09-30"))
        XCTAssertFalse(slot.contains(date(hour: 12, minute: 0), calendar: calendar))
    }

    // MARK: ActivationEngine.isSlotActive (pure form)

    func testActiveInsideSlotWhileUsable() {
        var config = AppConfig()
        config.slots = [TimeSlot(start: "12:00", end: "13:00")]
        let noon = date(hour: 12, minute: 30)
        XCTAssertTrue(ActivationEngine.isSlotActive(noon, config: config, calendar: calendar, screenUsable: true))
    }

    func testInactiveOutsideSlot() {
        var config = AppConfig()
        config.slots = [TimeSlot(start: "12:00", end: "13:00")]
        let afternoon = date(hour: 15, minute: 0)
        XCTAssertFalse(ActivationEngine.isSlotActive(afternoon, config: config, calendar: calendar, screenUsable: true))
    }

    func testInactiveWhenDisabled() {
        var config = AppConfig()
        config.enabled = false
        config.slots = [TimeSlot(start: "12:00", end: "13:00")]
        XCTAssertFalse(ActivationEngine.isSlotActive(date(hour: 12, minute: 30), config: config, calendar: calendar, screenUsable: true))
    }

    func testInactiveWhenScreenLockedOrAsleep() {
        var config = AppConfig()
        config.slots = [TimeSlot(start: "12:00", end: "13:00")]
        XCTAssertFalse(ActivationEngine.isSlotActive(date(hour: 12, minute: 30), config: config, calendar: calendar, screenUsable: false))
    }

    func testWeekendSkipping() {
        var config = AppConfig()
        config.slots = [TimeSlot(start: "12:00", end: "13:00")]
        // 2026-10-10 is a Saturday.
        let saturday = date(2026, 10, 10, hour: 12, minute: 30)
        XCTAssertTrue(config.skipWeekends)
        XCTAssertFalse(ActivationEngine.isSlotActive(saturday, config: config, calendar: calendar, screenUsable: true))
        config.skipWeekends = false
        XCTAssertTrue(ActivationEngine.isSlotActive(saturday, config: config, calendar: calendar, screenUsable: true))
    }
}
