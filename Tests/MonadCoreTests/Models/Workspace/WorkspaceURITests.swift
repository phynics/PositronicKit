import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class WorkspaceURITests {
    @Test
    func testWorkspaceURIParsingLocal() throws {
        let uri = WorkspaceURI(parsing: "local:/Users/test/Code/project")
        try #require(uri != nil)
        #expect(uri?.host == "local")
        #expect(uri?.path == "/Users/test/Code/project")
    }

    @Test
    func testWorkspaceURIParsingHost() throws {
        let uri = WorkspaceURI(parsing: "monad-server:/sessions/abc")
        try #require(uri != nil)
        #expect(uri?.host == "monad-server")
        #expect(uri?.path == "/sessions/abc")
        #expect(uri?.isServer == true)
        #expect(!(uri?.isClient == true))
    }

    @Test

    func testWorkspaceURIParsingInvalid() {
        let uri = WorkspaceURI(parsing: "invalid/some/path")
        #expect(uri == nil)
    }

    @Test

    func testWorkspaceURIToString() {
        let uri = WorkspaceURI(host: "local", path: "/var/tmp")
        #expect(uri.description == "local:/var/tmp")
    }

    @Test

    func testWorkspaceURIEquality() {
        let uri1 = WorkspaceURI(host: "local", path: "/var/tmp")
        let uri2 = WorkspaceURI(parsing: "local:/var/tmp")
        let uri3 = WorkspaceURI(host: "macbook", path: "/var/tmp")

        #expect(uri1 == uri2)
        #expect(uri1 != uri3)
    }
}
