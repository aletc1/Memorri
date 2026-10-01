import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct BusyCheckTests {
    private func makeDatabase(_ temp: TempDirectory) throws -> (StorageDatabase, AppPaths) {
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        return (database, paths)
    }

    private func add(_ database: StorageDatabase, state: AnalysisJobRecord.State) throws {
        try AnalysisStore(database: database).enqueue(AnalysisJobRecord(imageId: nil, state: state, createdAt: Date()))
    }

    @Test func noDatabaseFileIsNotBusy() {
        let temp = TempDirectory()
        #expect(BusyCheck.isBusy(databaseAt: temp.url.appendingPathComponent("none.sqlite")) == false)
    }

    @Test func aRunningJobIsBusy() throws {
        let temp = TempDirectory()
        let (database, paths) = try makeDatabase(temp)
        try add(database, state: .running)
        #expect(BusyCheck.isBusy(databaseAt: paths.database))
        try database.pool.close()
        #expect(BusyCheck.isBusy(databaseAt: paths.database))
    }

    @Test func otherStatesAreNotBusy() throws {
        let temp = TempDirectory()
        let (database, paths) = try makeDatabase(temp)
        for state in [AnalysisJobRecord.State.waiting, .finished, .failed] { try add(database, state: state) }
        #expect(BusyCheck.isBusy(databaseAt: paths.database) == false)
        try database.pool.close()
    }

    @Test func aDamagedFileIsNotBusy() throws {
        let temp = TempDirectory()
        let url = temp.url.appendingPathComponent("broken.sqlite")
        try Data("this is not a database".utf8).write(to: url)
        #expect(BusyCheck.isBusy(databaseAt: url) == false)
    }

    @Test func aDatabaseWithoutTheJobsTableIsNotBusy() throws {
        let temp = TempDirectory()
        let url = temp.url.appendingPathComponent("old.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE other (id INTEGER)") }
        try queue.close()
        #expect(BusyCheck.isBusy(databaseAt: url) == false)
    }

    @Test func checkingLeavesTheFileUntouched() throws {
        let temp = TempDirectory()
        let (database, paths) = try makeDatabase(temp)
        try add(database, state: .running)
        try database.pool.close()
        let before = try Data(contentsOf: paths.database)
        _ = BusyCheck.isBusy(databaseAt: paths.database)
        #expect(try Data(contentsOf: paths.database) == before)
    }
}
