import Foundation
import Testing
@testable import Umbra

struct DailyCounterStoreTests {
    @Test func persistsAggregateAndKeepsDatabasesIndependent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.sqlite")
        let secondURL = directory.appendingPathComponent("second.sqlite")
        let date = try instant("2026-10-20T12:00:00Z")
        let calendar = utcCalendar()

        do {
            let first = try DailyCounterStore(url: firstURL)
            let second = try DailyCounterStore(url: secondURL)
            #expect(try await first.recordDenial(at: date, calendar: calendar) == 1)
            #expect(try await first.recordDenial(at: date, calendar: calendar) == 2)
            #expect(try await second.total(at: date, calendar: calendar) == 0)
        }

        let reopened = try DailyCounterStore(url: firstURL, readOnly: true)
        #expect(try await reopened.total(at: date, calendar: calendar) == 2)
    }

    @Test func concurrentDenialsAreAtomic() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DailyCounterStore(url: directory.appendingPathComponent("counter.sqlite"))
        let date = try instant("2026-10-20T12:00:00Z")
        let calendar = utcCalendar()
        let increments = 100

        let results = try await withThrowingTaskGroup(of: Int64.self) { group in
            for _ in 0..<increments {
                group.addTask { try await store.recordDenial(at: date, calendar: calendar) }
            }
            var counts: [Int64] = []
            for try await count in group { counts.append(count) }
            return counts
        }

        #expect(Set(results).count == increments)
        #expect(results.sorted() == (1...Int64(increments)).map { $0 })
        #expect(try await store.total(at: date, calendar: calendar) == Int64(increments))
    }

    @Test func timezoneSelectsTheLocalDateBucket() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DailyCounterStore(url: directory.appendingPathComponent("counter.sqlite"))
        let instant = try instant("2026-03-08T04:30:00Z")
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let utc = utcCalendar()

        #expect(try await store.recordDenial(at: instant, calendar: newYork) == 1)
        #expect(try await store.recordDenial(at: instant, calendar: utc) == 1)
        #expect(try await store.total(at: instant, calendar: newYork) == 1)
        #expect(try await store.total(at: instant, calendar: utc) == 1)
    }

    @Test func bucketsHandleDSTDayRolloverAndClockMovingBackward() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DailyCounterStore(url: directory.appendingPathComponent("counter.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))

        let beforeSpringForward = try instant("2026-03-08T06:59:59Z")
        let afterSpringForward = try instant("2026-03-08T07:00:00Z")
        let clockMovedBack = try instant("2026-03-07T23:30:00Z")
        let nextLocalDay = try instant("2026-03-09T04:00:00Z")

        #expect(try await store.recordDenial(at: beforeSpringForward, calendar: calendar) == 1)
        #expect(try await store.recordDenial(at: clockMovedBack, calendar: calendar) == 1)
        #expect(try await store.recordDenial(at: afterSpringForward, calendar: calendar) == 2)
        #expect(try await store.total(at: beforeSpringForward, calendar: calendar) == 2)
        #expect(try await store.total(at: clockMovedBack, calendar: calendar) == 1)
        #expect(try await store.total(at: nextLocalDay, calendar: calendar) == 0)
    }

    @Test func readOnlyAndStorageFailuresThrow() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingURL = directory.appendingPathComponent("missing.sqlite")
        #expect(throws: DailyCounterStoreError.self) {
            try DailyCounterStore(url: missingURL, readOnly: true)
        }
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))

        let databaseURL = directory.appendingPathComponent("counter.sqlite")
        let writer = try DailyCounterStore(url: databaseURL)
        let readOnly = try DailyCounterStore(url: databaseURL, readOnly: true)
        let date = try instant("2026-10-20T12:00:00Z")
        #expect(try await readOnly.total(at: date, calendar: utcCalendar()) == 0)
        await #expect(throws: DailyCounterStoreError.readOnly) {
            try await readOnly.recordDenial(at: date, calendar: utcCalendar())
        }

        let invalidParentURL = directory.appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("counter.sqlite")
        #expect(throws: DailyCounterStoreError.self) {
            try DailyCounterStore(url: invalidParentURL)
        }
        #expect(try await writer.total(at: date, calendar: utcCalendar()) == 0)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func instant(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
