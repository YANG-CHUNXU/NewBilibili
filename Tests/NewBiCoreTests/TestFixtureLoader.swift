import Foundation

func loadFixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}
