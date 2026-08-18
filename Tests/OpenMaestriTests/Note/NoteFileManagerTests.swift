import XCTest
@testable import open_maestri

final class NoteFileManagerTests: XCTestCase {
    let nm = NoteFileManager.shared
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteFileManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Basics of reading and writing

    func testWriteAndRead() throws {
        let path = tmpDir.appendingPathComponent("test.md").path
        try nm.write(filePath: path, content: "Hello, World!")
        let content = try nm.read(filePath: path)
        XCTAssertEqual(content, "Hello, World!")
    }

    func testReadNonExistentThrows() {
        XCTAssertThrowsError(try nm.read(filePath: "/nonexistent/path.md"))
    }

    func testAtomicWriteCreatesFile() throws {
        let path = tmpDir.appendingPathComponent("atomic.md").path
        try nm.write(filePath: path, content: "atomic content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // Temporary files should have been cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"))
    }

    // MARK: - Row range read

    func testReadWithLineRangeHeader() throws {
        let path = tmpDir.appendingPathComponent("lines.md").path
        let content = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        try nm.write(filePath: path, content: content)

        let result = try nm.readWithLineRange(filePath: path)
        XCTAssertTrue(result.hasPrefix("[10 lines total]"))
    }

    func testReadWithSpecificLineRange() throws {
        let path = tmpDir.appendingPathComponent("range.md").path
        let content = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        try nm.write(filePath: path, content: content)

        let result = try nm.readWithLineRange(filePath: path, offset: 5, limit: 3)
        XCTAssertTrue(result.hasPrefix("[lines 5-7 of 20]"))
        XCTAssertTrue(result.contains("Line 5"))
        XCTAssertTrue(result.contains("Line 7"))
        XCTAssertFalse(result.contains("Line 8"))
    }

    // MARK: - Partial editing

    func testEditReplacesFirstOccurrence() throws {
        let path = tmpDir.appendingPathComponent("edit.md").path
        try nm.write(filePath: path, content: "foo bar foo")
        try nm.edit(filePath: path, oldText: "foo", newText: "baz")
        let result = try nm.read(filePath: path)
        XCTAssertEqual(result, "baz bar foo")
    }

    func testEditThrowsWhenTextNotFound() throws {
        let path = tmpDir.appendingPathComponent("edit2.md").path
        try nm.write(filePath: path, content: "hello world")
        XCTAssertThrowsError(try nm.edit(filePath: path, oldText: "notfound", newText: "x"))
    }

    // MARK: - File name cleaning

    func testSanitizedFilenameCreate() throws {
        let wsId = UUID()
        try FileManager.default.createDirectory(
            at: PersistenceManager.shared.notesDirURL(workspaceId: wsId),
            withIntermediateDirectories: true
        )
        let path = nm.managedPath(workspaceId: wsId, noteName: "My Note/Test")
        XCTAssertFalse(path.contains("/My Note/Test"))
        XCTAssertTrue(path.hasSuffix(".md"))
    }
}
