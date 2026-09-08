import Darwin
import Foundation
import HearthCore
@testable import HearthWeb
import XCTest

final class HearthWebTests: XCTestCase {
    func testPackagedResourceLookupFollowsExecutableSymlink() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("hearth-web-resources-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let contents = root.appendingPathComponent("Hearth.app/Contents")
        let executable = contents.appendingPathComponent("MacOS/hearth")
        let resources = contents.appendingPathComponent("Resources/Hearth_HearthWeb.bundle")
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        XCTAssertTrue(files.createFile(atPath: executable.path, contents: Data()))
        let html = "<!doctype html><style>body { color: black; }</style><p>Relocated packaged page</p><script>void 0;</script>"
        try html.write(to: resources.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let direct = try EmbeddedPage(executableURL: executable)
        XCTAssertEqual(String(decoding: direct.data, as: UTF8.self), html)
        let symlink = root.appendingPathComponent("hearth-link")
        try files.createSymbolicLink(at: symlink, withDestinationURL: executable)
        let linked = try EmbeddedPage(executableURL: symlink)
        XCTAssertEqual(String(decoding: linked.data, as: UTF8.self), html)
    }

    func testIncompleteInstalledBundleCannotFallBackToBuildResources() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("hearth-web-missing-resources-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let executable = root.appendingPathComponent("Hearth.app/Contents/MacOS/hearth")
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(files.createFile(atPath: executable.path, contents: Data()))
        XCTAssertThrowsError(try EmbeddedPage(executableURL: executable))
    }

    func testLaunchPageAndStopDoNotReadOrChangePower() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.url.host, "127.0.0.1")
        XCTAssertGreaterThan(fixture.port, 0)
        XCTAssertEqual(fixture.token.count, 64)
        XCTAssertTrue(fixture.token.allSatisfy { $0.isHexDigit })

        let response = try fixture.request("GET / HTTP/1.1\r\nHost: \(fixture.authority)\r\n\r\n")
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(response.headers["cache-control"], "no-store")
        XCTAssertEqual(response.headers["x-frame-options"], "DENY")
        XCTAssertEqual(response.headers["x-content-type-options"], "nosniff")
        XCTAssertEqual(response.headers["referrer-policy"], "no-referrer")
        XCTAssertEqual(response.headers["connection"], "close")
        XCTAssertEqual(response.headers["cross-origin-resource-policy"], "same-origin")
        let policy = try XCTUnwrap(response.headers["content-security-policy"])
        XCTAssertTrue(policy.contains("default-src 'none'"))
        XCTAssertTrue(policy.contains("script-src 'sha256-"))
        XCTAssertTrue(policy.contains("style-src 'sha256-"))
        XCTAssertTrue(policy.contains("frame-ancestors 'none'"))
        XCTAssertFalse(policy.contains("unsafe-inline"))
        XCTAssertNil(response.headers["access-control-allow-origin"])
        XCTAssertTrue(response.body.contains("Keep awake"))
        XCTAssertTrue(response.body.contains("Restore prior"))
        XCTAssertTrue(response.body.contains("Keep display on"))
        XCTAssertTrue(response.body.contains("Prevent idle lock"))
        XCTAssertTrue(response.body.contains("Manual lock, passwords, authentication"))
        XCTAssertTrue(response.body.contains("history.replaceState"))
        XCTAssertFalse(response.body.contains("localStorage"))
        XCTAssertFalse(response.body.contains(fixture.token))
        XCTAssertEqual(fixture.runner.readCount, 0)
        XCTAssertEqual(fixture.runner.applyCount, 0)

        try fixture.server.stop()
        try fixture.server.stop()
        try fixture.server.wait()
        XCTAssertEqual(fixture.runner.applyCount, 0)
    }

    func testEachRunUsesANewTokenAndRejectsInvalidPorts() throws {
        let first = try Fixture()
        defer { first.cleanup() }
        let second = try Fixture()
        defer { second.cleanup() }
        XCTAssertFalse(first.token == second.token)
        XCTAssertThrowsError(try first.server.start())
        let server = HearthWebServer(service: first.service)
        XCTAssertThrowsError(try server.start(port: -1))
        XCTAssertThrowsError(try server.start(port: 65_536))
        try server.stop()
        XCTAssertThrowsError(try server.wait())
    }

    func testAPIRoutesRequireOneExactBearerToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for authorization in [
            "",
            "Authorization: Bearer wrong\r\n",
            "Authorization: Basic wrong\r\n",
            "Authorization: bearer \(fixture.token)\r\n",
            "Authorization: Bearer \(fixture.token)\r\nAuthorization: Bearer \(fixture.token)\r\n",
        ] {
            let response = try fixture.request(
                "GET /api/status HTTP/1.1\r\nHost: \(fixture.authority)\r\n\(authorization)\r\n"
            )
            XCTAssertEqual(response.code, 401)
        }
        XCTAssertEqual(fixture.runner.readCount, 0)
        let response = try fixture.api("/api/status")
        XCTAssertEqual(response.code, 200)
        let json = try fixture.json(response)
        XCTAssertEqual(json["currentSource"] as? String, "AC Power")
        XCTAssertEqual(json["schemaVersion"] as? Int, 4)
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        let displayProfiles = try XCTUnwrap(json["displayProfiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(displayProfiles.count, 2)
        XCTAssertEqual(profiles.first { $0["profile"] as? String == "battery" }?["actualMinutes"] as? Int, 5)
        XCTAssertEqual(displayProfiles.first { $0["profile"] as? String == "battery" }?["actualMinutes"] as? Int, 2)
        XCTAssertTrue(profiles.allSatisfy { $0["setting"] as? String == "system" })
        XCTAssertTrue(displayProfiles.allSatisfy { $0["setting"] as? String == "display" })
    }

    func testHostMustExactlyMatchAssignedLoopbackAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for host in [
            "",
            "Host: 127.0.0.1\r\n",
            "Host: localhost:\(fixture.port)\r\n",
            "Host: 127.0.0.1:\(fixture.port + 1)\r\n",
            "Host: example.com:\(fixture.port)\r\n",
            "Host: \(fixture.authority)\r\nHost: \(fixture.authority)\r\n",
        ] {
            let response = try fixture.request("GET / HTTP/1.1\r\n\(host)\r\n")
            XCTAssertEqual(response.code, 403)
        }
        XCTAssertEqual(fixture.runner.applyCount, 0)
    }

    func testOriginChecksApplyToPageStatusAndWrites() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for origin in ["null", "https://\(fixture.authority)", "http://localhost:\(fixture.port)", "http://evil.example", "\(fixture.origin)/"] {
            let response = try fixture.api("/api/status", extraHeaders: "Origin: \(origin)\r\n")
            XCTAssertEqual(response.code, 403)
            let page = try fixture.request(
                "GET / HTTP/1.1\r\nHost: \(fixture.authority)\r\nOrigin: \(origin)\r\n\r\n"
            )
            XCTAssertEqual(page.code, 403)
        }
        XCTAssertEqual(try fixture.api("/api/status", extraHeaders: "Origin: \(fixture.origin)\r\n").code, 200)
        XCTAssertEqual(try fixture.api("/api/status", extraHeaders: "Origin: \(fixture.origin)\r\nOrigin: \(fixture.origin)\r\n").code, 403)
        XCTAssertEqual(try fixture.api("/api/status", extraHeaders: "Sec-Fetch-Site: cross-site\r\n").code, 403)
        let noOrigin = try fixture.api("/api/power", method: "POST", body: #"{"action":"on","target":"both"}"#)
        XCTAssertEqual(noOrigin.code, 403)
        XCTAssertEqual(fixture.runner.applyCount, 0)
    }

    func testRoutesMethodsAndContentTypeAreAllowlisted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.api("/missing").code, 404)
        XCTAssertEqual(try fixture.api("/api/status?token=anything").code, 404)
        XCTAssertEqual(try fixture.api("http://\(fixture.authority)/api/status").code, 404)
        XCTAssertEqual(try fixture.api("/", method: "POST").code, 405)
        XCTAssertEqual(try fixture.api("/api/status", method: "POST").code, 405)
        XCTAssertEqual(try fixture.api("/api/power").code, 405)
        XCTAssertEqual(try fixture.api("/api/power", method: "OPTIONS").code, 405)
        let response = try fixture.request(
            "POST /api/power HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\nOrigin: \(fixture.origin)\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}"
        )
        XCTAssertEqual(response.code, 415)
        XCTAssertEqual(fixture.runner.applyCount, 0)
    }

    func testStrictPowerValidationDoesNotReachRunner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let invalidBodies = [
            #"{}"#,
            #"[]"#,
            #"{"action":"on"}"#,
            #"{"target":"both"}"#,
            #"{"action":"off","target":"both"}"#,
            #"{"action":"on","target":"ups"}"#,
            #"{"action":"on","target":"both","extra":true}"#,
            #"{"action":"on","target":"both","minutes":1}"#,
            #"{"action":"restore","target":"both","minutes":1}"#,
            #"{"action":"on","target":"both","minutes":null}"#,
            #"{"action":"sleep","target":"both"}"#,
            #"{"action":"sleep","target":"both","minutes":0}"#,
            #"{"action":"sleep","target":"both","minutes":-1}"#,
            #"{"action":"sleep","target":"both","minutes":1.5}"#,
            #"{"action":"sleep","target":"both","minutes":true}"#,
            #"{"action":"sleep","target":"both","minutes":"10"}"#,
            #"{"action":"sleep","target":"both","minutes":2147483648}"#,
            #"{"action":"sleep","target":"both","minutes":null}"#,
            #"{"action":"sleep","target":"both","minutes":999999999999999999999999}"#,
            #"{"action":"on","target":"both","setting":null}"#,
            #"{"action":"on","target":"both","setting":"Display"}"#,
            #"{"action":"on","target":"both","setting":"displaysleep"}"#,
            #"{"action":"on","target":"both","setting":"lock"}"#,
            #"{"action":"on","target":"both","setting":1}"#,
            #"{"action":"on","target":"both","setting":true}"#,
            #"{"action":"on","target":"both","setting":[]}"#,
            #"{"action":"on","target":"both","setting":{}}"#,
            #"{"action":"on","target":"both","setting":"display","extra":1}"#,
            #"{"action":"on","target":"both","setting":"display","minutes":10}"#,
            #"{"action":"sleep","target":"both","setting":"display","minutes":null}"#,
            #"{"action":"restore","target":"both","setting":"display","minutes":10}"#,
            #"{"action":"on","action":"on","target":"both"}"#,
            #"{"action":"on","target":"both","target":"battery"}"#,
            #"{"action":"sleep","target":"both","minutes":1,"minutes":2}"#,
            #"{"action":"on","target":"both","setting":"system","setting":"display"}"#,
            #"{"action":"on","target":"both","setting":"display","setting":"display"}"#,
            #"{"action":"on","target":"both","setting":"display","sett\u0069ng":"system"}"#,
            #"{"action":"on","target":"both","t\u0061rget":"adapter"}"#,
            "{not-json",
        ]
        for body in invalidBodies {
            let response = try fixture.api("/api/power", method: "POST", body: body, extraHeaders: "Origin: \(fixture.origin)\r\n")
            XCTAssertEqual(response.code, 400, "Invalid body accepted: \(body)")
        }
        XCTAssertEqual(fixture.runner.applyCount, 0)
        XCTAssertEqual(fixture.runner.readCount, 0)
    }

    func testLockRouteRejectsUnsafeHeadersMethodsAndBodies() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let body = #"{"action":"on"}"#
        XCTAssertEqual(try fixture.api("/api/lock").code, 405)
        XCTAssertEqual(try fixture.api("/api/lock", method: "OPTIONS").code, 405)
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: body).code, 403)
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: body, extraHeaders: "Origin: null\r\n").code, 403)
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: body, extraHeaders: "Origin: \(fixture.origin)\r\nOrigin: \(fixture.origin)\r\n").code, 403)
        for (host, token, contentType, expected) in [
            ("evil.example", fixture.token, "application/json", 403),
            (fixture.authority, "invalid-token", "application/json", 401),
            (fixture.authority, fixture.token, "text/plain", 415),
        ] {
            let response = try fixture.request(
                "POST /api/lock HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\nOrigin: \(fixture.origin)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            )
            XCTAssertEqual(response.code, expected)
        }
        let invalidBodies = [
            "{}", "[]", "null", "{invalid", #"{"action":null}"#, #"{"action":true}"#,
            #"{"action":1}"#, #"{"action":[]}"#, #"{"action":{}}"#,
            #"{"action":"off"}"#, #"{"action":"status"}"#, #"{"action":"setup"}"#,
            #"{"action":"authorize"}"#, #"{"action":"on","target":"both"}"#,
            #"{"action":"restore","setting":"display"}"#, #"{"action":"on","minutes":1}"#,
            #"{"action":"on","extra":null}"#, #"{"action":"on","action":"restore"}"#,
            #"{"action":"on","act\u0069on":"on"}"#,
        ]
        for body in invalidBodies {
            let response = try fixture.api("/api/lock", method: "POST", body: body, extraHeaders: "Origin: \(fixture.origin)\r\n")
            XCTAssertEqual(response.code, 400, body)
        }
        XCTAssertEqual(try fixture.api("/api/lock/setup", method: "POST", body: "{}").code, 404)
        let oversized = String(repeating: " ", count: 4_097)
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: oversized, extraHeaders: "Origin: \(fixture.origin)\r\n").code, 413)
        let chunk = String(repeating: " ", count: 4_097)
        let streamed = try fixture.request(
            "POST /api/lock HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\nOrigin: \(fixture.origin)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1001\r\n\(chunk)\r\n0\r\n\r\n"
        )
        XCTAssertEqual(streamed.code, 413)
        XCTAssertEqual(fixture.runner.readCount, 0)
        XCTAssertEqual(fixture.runner.applyCount, 0)
        XCTAssertEqual(fixture.saver.writeCount, 0)
    }

    func testLockCoordinatesAvailableProfilesAndPreservesBorrowedOverride() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.runner.apply([PowerChange(profile: .battery, minutes: 1)])
        _ = try fixture.service.perform(PowerRequest(action: .on, target: .battery))
        let headers = "Origin: \(fixture.origin)\r\n"
        let enabled = try fixture.api("/api/lock", method: "POST", body: #"{"action":"on"}"#, extraHeaders: headers)
        XCTAssertEqual(enabled.code, 200)
        XCTAssertEqual(try fixture.json(enabled)["succeeded"] as? Bool, true)
        let status = try fixture.service.status()
        XCTAssertEqual(status.idleLock?.phase, .active)
        XCTAssertEqual(status.idleLock?.dependencies.count, 4)
        XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertTrue(status.idleLock?.dependencies.filter { $0.setting == .system }.allSatisfy { !$0.acquired } == true)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        let normalStatus = try fixture.json(fixture.api("/api/status"))
        XCTAssertEqual((normalStatus["idleLock"] as? [String: Any])?["phase"] as? String, "active")
        for setting in PowerSetting.allCases {
            for action in ["on", "restore", "sleep"] {
                let minutes = action == "sleep" ? ",\"minutes\":9" : ""
                let body = "{\"action\":\"\(action)\",\"target\":\"both\",\"setting\":\"\(setting.rawValue)\"\(minutes)}"
                let response = try fixture.api("/api/power", method: "POST", body: body, extraHeaders: headers)
                XCTAssertNotEqual(response.code, 200, "Required dependency accepted: \(body)")
            }
        }
        let restored = try fixture.api("/api/lock", method: "POST", body: #"{"action":"restore"}"#, extraHeaders: headers)
        XCTAssertEqual(restored.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        let after = try fixture.service.status()
        XCTAssertEqual(after.idleLock?.phase, .off)
        XCTAssertEqual(after.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertTrue(after.hasManagedChanges)
        XCTAssertEqual(try fixture.saver.observe().delaySeconds, 300)
    }

    func testLockUnavailablePartialRestoreAndUnknownCompletionAreTruthful() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let headers = "Origin: \(fixture.origin)\r\n"
        for availability in [ScreenSaverAvailability.setupRequired, .managed, .unavailable] {
            fixture.saver.configure(availability: availability)
            let response = try fixture.api("/api/lock", method: "POST", body: #"{"action":"on"}"#, extraHeaders: headers)
            XCTAssertEqual(response.code, 409)
            XCTAssertEqual(try fixture.json(response)["succeeded"] as? Bool, false)
            XCTAssertEqual(fixture.saver.writeCount, 0)
            XCTAssertEqual(fixture.runner.applyCount, 0)
        }
        fixture.saver.configure()
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: #"{"action":"on"}"#, extraHeaders: headers).code, 200)
        fixture.saver.configure(failure: .rejected("Fake preference write rejected."))
        let failedRestore = try fixture.api("/api/lock", method: "POST", body: #"{"action":"restore"}"#, extraHeaders: headers)
        XCTAssertEqual(failedRestore.code, 409)
        XCTAssertEqual(try fixture.service.status().idleLock?.phase, .needsRestore)
        XCTAssertTrue(try fixture.service.status().idleLock?.hasManagedChanges == true)
        fixture.saver.configure()
        XCTAssertEqual(try fixture.api("/api/lock", method: "POST", body: #"{"action":"restore"}"#, extraHeaders: headers).code, 200)
        fixture.saver.configure(failure: .completionUnknown("Fake completion unknown."))
        let uncertain = try fixture.api("/api/lock", method: "POST", body: #"{"action":"on"}"#, extraHeaders: headers)
        XCTAssertEqual(uncertain.code, 409)
        let lock = try XCTUnwrap(fixture.service.status().idleLock)
        XCTAssertEqual(lock.phase, .uncertain)
        XCTAssertFalse(lock.canEnable)
        XCTAssertFalse(lock.canRestore)
    }

    func testValidatedActionsUseSharedServiceAndPreserveStopSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let headers = "Origin: \(fixture.origin)\r\n"
        let on = try fixture.api("/api/power", method: "POST", body: #"{"action":"on","target":"both"}"#, extraHeaders: headers)
        XCTAssertEqual(on.code, 200)
        XCTAssertEqual(try fixture.json(on)["succeeded"] as? Bool, true)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])
        let outcomes = try XCTUnwrap(try fixture.json(on)["outcomes"] as? [[String: Any]])
        XCTAssertTrue(outcomes.allSatisfy { $0["setting"] as? String == "system" })

        let restore = try fixture.api("/api/power", method: "POST", body: #"{"action":"restore","target":"battery"}"#, extraHeaders: headers)
        XCTAssertEqual(restore.code, 200)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])

        let sleep = try fixture.api("/api/power", method: "POST", body: #"{"action":"sleep","target":"adapter","minutes":17}"#, extraHeaders: headers)
        XCTAssertEqual(sleep.code, 200)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 17])
        let applyCount = fixture.runner.applyCount
        try fixture.server.stop()
        XCTAssertEqual(fixture.runner.applyCount, applyCount)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 17])
    }

    func testDisplayActionsTargetsAndRestoreAreIndependentFromSystem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let headers = "Origin: \(fixture.origin)\r\n"
        let on = try fixture.api("/api/power", method: "POST", body: #"{"action":"on","target":"both","setting":"display"}"#, extraHeaders: headers)
        XCTAssertEqual(on.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        let outcomes = try XCTUnwrap(try fixture.json(on)["outcomes"] as? [[String: Any]])
        XCTAssertTrue(outcomes.allSatisfy { $0["setting"] as? String == "display" })

        let systemRestore = try fixture.api("/api/power", method: "POST", body: #"{"action":"restore","target":"both"}"#, extraHeaders: headers)
        XCTAssertEqual(systemRestore.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        let status = try fixture.json(try fixture.api("/api/status"))
        let system = try XCTUnwrap(status["profiles"] as? [[String: Any]])
        let display = try XCTUnwrap(status["displayProfiles"] as? [[String: Any]])
        XCTAssertTrue(system.allSatisfy { $0["originalMinutes"] == nil })
        XCTAssertEqual(display.first { $0["profile"] as? String == "battery" }?["originalMinutes"] as? Int, 2)
        XCTAssertEqual(display.first { $0["profile"] as? String == "adapter" }?["originalMinutes"] as? Int, 10)

        let restore = try fixture.api("/api/power", method: "POST", body: #"{"action":"restore","target":"battery","setting":"display"}"#, extraHeaders: headers)
        XCTAssertEqual(restore.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 0])
        let sleep = try fixture.api("/api/power", method: "POST", body: #"{"action":"sleep","target":"adapter","minutes":17,"setting":"display"}"#, extraHeaders: headers)
        XCTAssertEqual(sleep.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 17])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        XCTAssertFalse(try fixture.service.status().hasManagedChanges)
    }

    func testEscapedValidSettingFieldIsAcceptedWithoutDuplicate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let response = try fixture.api(
            "/api/power", method: "POST",
            body: #"{"action":"on","target":"battery","sett\u0069ng":"display"}"#,
            extraHeaders: "Origin: \(fixture.origin)\r\n"
        )
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 10])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
    }

    func testAlternateJSONEncodingCannotHideDuplicateFields() throws {
        let router = RequestRouter(authority: "127.0.0.1:12345", token: String(repeating: "0", count: 64), page: try EmbeddedPage())
        let duplicate = #"{"action":"on","target":"both","setting":"system","setting":"display"}"#
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            XCTAssertThrowsError(try router.decodePower(XCTUnwrap(duplicate.data(using: encoding))))
        }
    }

    func testDeclaredAndStreamedBodiesAreBounded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = "POST /api/power HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\nOrigin: \(fixture.origin)\r\nContent-Type: application/json\r\n"
        XCTAssertEqual(try fixture.request(base + "Content-Length: 4097\r\n\r\n").code, 413)
        let oversized = String(repeating: "x", count: 4_097)
        let chunked = base + "Transfer-Encoding: chunked\r\n\r\n1001\r\n\(oversized)\r\n0\r\n\r\n"
        XCTAssertEqual(try fixture.request(chunked).code, 413)
        let getBody = "GET /api/status HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\nContent-Length: 1\r\n\r\nx"
        XCTAssertEqual(try fixture.request(getBody).code, 400)
        let tooManyHeaders = "GET / HTTP/1.1\r\nHost: \(fixture.authority)\r\nX-Padding: \(String(repeating: "x", count: 9_000))\r\n\r\n"
        XCTAssertEqual(try fixture.request(tooManyHeaders).code, 431)
        let expect = base + "Content-Length: 2\r\nExpect: 100-continue\r\n\r\n{}"
        XCTAssertEqual(try fixture.request(expect).code, 400)
        let extensions = base + "Transfer-Encoding: chunked\r\n\r\n1;pad=\(String(repeating: "x", count: 17_000))\r\nx\r\n0\r\n\r\n"
        XCTAssertEqual(try fixture.request(extensions).code, 413)
        XCTAssertEqual(fixture.runner.applyCount, 0)
    }

    func testPipeliningCannotQueuePowerChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = "GET / HTTP/1.1\r\nHost: \(fixture.authority)\r\n\r\n"
        let body = #"{"action":"on","target":"both"}"#
        let second = "POST /api/power HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\nOrigin: \(fixture.origin)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = try fixture.request(first + second)
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(fixture.runner.applyCount, 0)
        XCTAssertFalse(response.raw.contains("HTTP/1.1 200 OK\r\nHTTP/1.1"))
    }

    func testBlockingCoreCallDoesNotBlockPageOrValidation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let releaseRead = DispatchSemaphore(value: 0)
        let enteredRead = DispatchSemaphore(value: 0)
        fixture.runner.blockReads(entered: enteredRead, release: releaseRead)
        defer { releaseRead.signal() }
        let socket = try fixture.connect()
        defer { Darwin.close(socket) }
        try fixture.send("GET /api/status HTTP/1.1\r\nHost: \(fixture.authority)\r\nAuthorization: Bearer \(fixture.token)\r\n\r\n", to: socket)
        XCTAssertEqual(enteredRead.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try fixture.request("GET / HTTP/1.1\r\nHost: \(fixture.authority)\r\n\r\n").code, 200)
        XCTAssertEqual(try fixture.request("GET /api/status HTTP/1.1\r\nHost: \(fixture.authority)\r\n\r\n").code, 401)
        releaseRead.signal()
        XCTAssertEqual(try fixture.receive(from: socket).code, 200)
    }
}

struct Response {
    let code: Int
    let headers: [String: String]
    let body: String
    let raw: String

    init(_ data: Data) throws {
        raw = String(decoding: data, as: UTF8.self)
        let halves = raw.components(separatedBy: "\r\n\r\n")
        let lines = halves[0].components(separatedBy: "\r\n")
        code = try XCTUnwrap(lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) })
        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                parsedHeaders[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        headers = parsedHeaders
        body = halves.dropFirst().joined(separator: "\r\n\r\n")
    }
}

final class Fixture {
    let runner = FakeRunner()
    let saver = FakeScreenSaver()
    let directory: URL
    let service: HearthService
    let server: HearthWebServer
    let url: URL
    let port: Int
    let token: String
    var authority: String { "127.0.0.1:\(port)" }
    var origin: String { "http://\(authority)" }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-web-test-\(UUID().uuidString)")
        service = HearthService(
            runner: runner, stateDirectory: directory,
            idleLockController: IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        )
        server = HearthWebServer(service: service)
        url = try server.start()
        port = try XCTUnwrap(url.port)
        token = try XCTUnwrap(url.fragment)
    }

    final class FakeScreenSaver: ScreenSaverControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = ScreenSaverStoredValue.integer(300)
        private var availability = ScreenSaverAvailability.ready
        private var failure: ScreenSaverError?
        private var readFailure: String?
        private var writes = 0
        var writeCount: Int { lock.withLock { writes } }

        func observe() throws -> ScreenSaverObservation {
            try lock.withLock {
                if let readFailure { throw ScreenSaverError.unavailable(readFailure) }
                let current = configuration()
                return ScreenSaverObservation(
                    delaySeconds: current.effectiveSeconds, availability: availability,
                    message: "Fake Lock \(availability.rawValue).", configuration: current
                )
            }
        }

        func apply(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws {
            try lock.withLock {
                writes += 1
                if let failure { throw failure }
                guard availability == .ready, configuration() == expected else {
                    throw ScreenSaverError.rejected("Fake Lock denied.")
                }
                storedValue = value
            }
        }

        private func configuration() -> ScreenSaverConfiguration {
            let seconds: Int
            switch storedValue {
            case .absent: seconds = 300
            case .integer(let value): seconds = value
            }
            return ScreenSaverConfiguration(
                storedValue: storedValue, effectiveSeconds: seconds,
                dictionarySource: .currentUserCurrentHost,
                valueSource: storedValue == .absent ? .registeredDefaults : .currentUserCurrentHost,
                contextFingerprint: String(repeating: "a", count: 64)
            )
        }

        func configure(availability: ScreenSaverAvailability = .ready, failure: ScreenSaverError? = nil, readFailure: String? = nil) {
            lock.withLock {
                self.availability = availability
                self.failure = failure
                self.readFailure = readFailure
            }
        }
    }

    func cleanup() {
        try? server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func api(_ path: String, method: String = "GET", body: String = "", extraHeaders: String = "") throws -> Response {
        try request(
            "\(method) \(path) HTTP/1.1\r\nHost: \(authority)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extraHeaders)\r\n\(body)"
        )
    }

    func json(_ response: Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
    }

    func request(_ value: String) throws -> Response {
        let socket = try connect()
        defer { Darwin.close(socket) }
        try send(value, to: socket)
        return try receive(from: socket)
    }

    func connect() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }

    func send(_ value: String, to socket: Int32) throws {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(socket, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw POSIXError(.EIO) }
                sent += count
            }
        }
    }

    func receive(from socket: Int32) throws -> Response {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == ECONNRESET && !data.isEmpty { break }
                throw POSIXError(.EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 131_072 else { throw POSIXError(.EFBIG) }
        }
        return try Response(data)
    }
}

// Tests use this lock-protected in-memory runner; no subprocess or authorization path is reachable.
final class FakeRunner: PowerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PowerProfile: Int] = [.battery: 5, .adapter: 0]
    private var displayValues: [PowerProfile: Int] = [.battery: 2, .adapter: 10]
    private var reads = 0
    private var applies = 0
    private var entered: DispatchSemaphore?
    private var release: DispatchSemaphore?

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return applies
    }

    var settings: PowerSettings {
        lock.lock()
        defer { lock.unlock() }
        return PowerSettings(values: values, currentSource: "AC Power", displayValues: displayValues)
    }

    func blockReads(entered: DispatchSemaphore, release: DispatchSemaphore) {
        lock.lock()
        defer { lock.unlock() }
        self.entered = entered
        self.release = release
    }

    func readSettings() throws -> PowerSettings {
        lock.lock()
        reads += 1
        let entered = self.entered
        let release = self.release
        self.entered = nil
        self.release = nil
        lock.unlock()
        entered?.signal()
        if let release { _ = release.wait(timeout: .now() + 10) }
        return settings
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        lock.lock()
        defer { lock.unlock() }
        applies += 1
        return changes.map { change in
            if change.setting == .display {
                displayValues[change.profile] = change.minutes
            } else {
                values[change.profile] = change.minutes
            }
            return CommandOutcome(profile: change.profile, exitCode: 0, setting: change.setting)
        }
    }
}
