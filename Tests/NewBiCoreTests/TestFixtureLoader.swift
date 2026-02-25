import Foundation
import XCTest

enum FixtureLoaderError: Error {
    case notFound(name: String, candidates: [String], bundlePath: String)
    case unreadable(name: String, url: URL, underlying: Error)
}

func loadFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let bundle = Bundle.module
    let bundlePath = bundle.bundleURL.path
    let fileManager = FileManager.default
    var candidates: [String] = []

    if let url = bundle.url(forResource: name, withExtension: "html") {
        return try readFixture(name: name, from: url, file: file, line: line)
    }
    appendCandidate("\(bundlePath)/\(name).html", to: &candidates)

    if let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") {
        return try readFixture(name: name, from: url, file: file, line: line)
    }
    appendCandidate("\(bundlePath)/Fixtures/\(name).html", to: &candidates)

    if let resourceURL = bundle.resourceURL {
        let rootURL = resourceURL.appendingPathComponent("\(name).html")
        appendCandidate(rootURL.path, to: &candidates)
        if fileManager.fileExists(atPath: rootURL.path) {
            return try readFixture(name: name, from: rootURL, file: file, line: line)
        }

        let fixturesURL = resourceURL.appendingPathComponent("Fixtures/\(name).html")
        appendCandidate(fixturesURL.path, to: &candidates)
        if fileManager.fileExists(atPath: fixturesURL.path) {
            return try readFixture(name: name, from: fixturesURL, file: file, line: line)
        }
    }

    let message = """
    Fixture '\(name).html' not found in test bundle.
    Bundle: \(bundlePath)
    Tried:
    - \(candidates.joined(separator: "\n- "))
    """
    XCTFail(message, file: file, line: line)
    throw FixtureLoaderError.notFound(name: name, candidates: candidates, bundlePath: bundlePath)
}

private func readFixture(name: String, from url: URL, file: StaticString, line: UInt) throws -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        XCTFail("Failed to read fixture '\(name).html' at \(url.path): \(error)", file: file, line: line)
        throw FixtureLoaderError.unreadable(name: name, url: url, underlying: error)
    }
}

private func appendCandidate(_ path: String, to candidates: inout [String]) {
    guard !candidates.contains(path) else { return }
    candidates.append(path)
}
