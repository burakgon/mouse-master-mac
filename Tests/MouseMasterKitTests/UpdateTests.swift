import XCTest
@testable import MouseMasterKit

final class UpdateTests: XCTestCase {
    func testVersionParts() {
        XCTAssertEqual(AppVersion.parts("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(AppVersion.parts("1.2"), [1, 2])
        XCTAssertEqual(AppVersion.parts("1.10.0-beta.2"), [1, 10, 0])
        XCTAssertEqual(AppVersion.parts(" V2.0+build.7 "), [2, 0])
    }

    func testVersionOrder() {
        XCTAssertTrue(AppVersion.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertTrue(AppVersion.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("2", than: "1.99"))
        XCTAssertFalse(AppVersion.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(AppVersion.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(AppVersion.isNewer("1.0.9", than: "1.1"))
        XCTAssertFalse(AppVersion.isNewer("1.1.0", than: "1.1.0"))
    }

    private func release(_ json: String) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecodesTheLatestRelease() throws {
        let r = try release("""
        {"tag_name": "v1.2.0", "name": "Mouse Master 1.2.0", "body": "- Faster zoom",
         "html_url": "https://github.com/burakgon/mouse-master-mac/releases/tag/v1.2.0",
         "draft": false, "prerelease": false, "author": {"login": "burakgon"},
         "assets": [
           {"name": "Mouse-Master-1.2.0.zip.sha256", "size": 90,
            "browser_download_url": "https://github.com/burakgon/mouse-master-mac/releases/download/v1.2.0/Mouse-Master-1.2.0.zip.sha256"},
           {"name": "Mouse-Master-1.2.0.zip", "size": 4100000, "content_type": "application/zip",
            "browser_download_url": "https://github.com/burakgon/mouse-master-mac/releases/download/v1.2.0/Mouse-Master-1.2.0.zip"}
         ]}
        """)
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.notes, "- Faster zoom")
        XCTAssertEqual(r.archive?.name, "Mouse-Master-1.2.0.zip")
        XCTAssertEqual(r.archive?.size, 4_100_000)
        XCTAssertFalse(r.draft)
    }

    func testPicksTheZipForTheVersion() throws {
        let r = try release("""
        {"tag_name": "1.3.0", "html_url": "https://example.com/r",
         "assets": [{"name": "Other-1.2.0.zip", "size": 1, "browser_download_url": "https://example.com/a.zip"},
                    {"name": "Mouse-Master-1.3.0.zip", "size": 2, "browser_download_url": "https://example.com/b.zip"}]}
        """)
        XCTAssertEqual(r.version, "1.3.0")
        XCTAssertEqual(r.archive?.url.absoluteString, "https://example.com/b.zip")
        XCTAssertNil(r.notes)
    }

    func testTakesTheOnlyZipWhateverItsName() throws {
        // Releases attach Mouse-Master.zip, so .../releases/latest/download/Mouse-Master.zip works.
        let r = try release("""
        {"tag_name": "v1.1.0", "html_url": "https://example.com/r",
         "assets": [{"name": "Mouse-Master.zip", "size": 3, "browser_download_url": "https://example.com/m.zip"},
                    {"name": "Mouse-Master.zip.sha256", "size": 1, "browser_download_url": "https://example.com/m.sha256"}]}
        """)
        XCTAssertEqual(r.archive?.name, "Mouse-Master.zip")
    }

    func testNoArchiveWhenTheZipIsAmbiguousOrMissing() throws {
        let two = try release("""
        {"tag_name": "v2.0.0", "html_url": "https://example.com/r",
         "assets": [{"name": "a.zip", "size": 1, "browser_download_url": "https://example.com/a.zip"},
                    {"name": "b.zip", "size": 1, "browser_download_url": "https://example.com/b.zip"}]}
        """)
        XCTAssertNil(two.archive)
        let none = try release(#"{"tag_name": "v2.0.0", "html_url": "https://example.com/r", "assets": []}"#)
        XCTAssertNil(none.archive)
    }

    func testOlderStateWithoutUpdatesStillDecodes() throws {
        var g = General()
        g.checkForUpdates = false
        let data = try JSONEncoder().encode(g)
        XCTAssertFalse(try JSONDecoder().decode(General.self, from: data).checkForUpdates)
        // A configuration written before the setting existed checks for updates.
        XCTAssertTrue(try JSONDecoder().decode(General.self, from: Data(#"{"osd": false}"#.utf8)).checkForUpdates)
    }
}
