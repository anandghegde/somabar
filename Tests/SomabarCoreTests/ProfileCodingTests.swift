import Foundation
import Testing
@testable import SomabarCore

@Suite struct ProfileCodingTests {
    private let docker = ItemKey(bundleID: "com.docker.docker")

    @Test func decodesAProfileWrittenBeforeTheNotchGuard() throws {
        let profile = Profile.everyday(layout: Layout(shown: [docker]))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any] ?? [:]
        #expect(json["notchGuarded"] != nil)
        json["notchGuarded"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded.notchGuarded.isEmpty)
        #expect(decoded.layout == profile.layout)
        #expect(decoded.name == profile.name)
    }

    @Test func guardedItemsRoundTrip() throws {
        var profile = Profile.everyday(layout: Layout(hidden: [docker]))
        profile.notchGuarded = [GuardedItem(key: docker, width: 32)]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == profile)
    }
}
