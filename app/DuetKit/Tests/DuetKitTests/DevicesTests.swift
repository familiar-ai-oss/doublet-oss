import Foundation
import Testing
@testable import DuetKit

// The user's devices, what each has open, and places sent between them (Open on iPad, Write on iPad), as the hub sends
// them and the store keeps them; and notes written on the plan.

@Test func theWelcomeCarriesTheDevicesAndALaterListReplacesThem() throws {
    let welcome = #"{"type":"welcome","protocol":1,"device":"mac","headSeq":7,"replayFrom":0,"reset":false,"devices":[{"device":"ipad","online":false,"lastSeen":1760000000000,"kind":"ipad"},{"device":"mac","online":true,"lastSeen":1760000100000,"kind":"mac"},{"device":"test","online":false}]}"#
    guard case .welcome(_, let device, _, _, _, let devices) = try JSONDecoder().decode(ServerFrame.self, from: Data(welcome.utf8)) else {
        Issue.record("not a welcome")
        return
    }
    #expect(device == "mac")
    #expect(devices?.map(\.device) == ["ipad", "mac", "test"])
    #expect(devices?.first?.lastSeenDate == Date(timeIntervalSince1970: 1_760_000_000))
    #expect(devices?.last?.kind == nil && devices?.last?.lastSeen == nil)
    // A hub from before the device list sends none.
    let old = #"{"type":"welcome","protocol":1,"device":"mac","headSeq":7,"replayFrom":0,"reset":false}"#
    guard case .welcome(_, _, _, _, _, let none) = try JSONDecoder().decode(ServerFrame.self, from: Data(old.utf8)) else {
        Issue.record("not a welcome")
        return
    }
    #expect(none == nil)
    let list = #"{"type":"devices","devices":[{"device":"ipad","online":true,"lastSeen":1760000200000,"kind":"ipad"}]}"#
    #expect(try JSONDecoder().decode(ServerFrame.self, from: Data(list.utf8)) == .devices([DeviceInfo(device: "ipad", online: true, lastSeen: 1_760_000_200_000, kind: "ipad")]))
}

@Test func aSentPlaceArrivesAsTheSenderDescribedIt() throws {
    let json = #"{"type":"place_sent","id":"p-1","from":"mac","to":"ipad","place":{"file":{"path":"/p/Lexer.swift","line":27}},"title":"Lexer.swift","ts":1760000300000}"#
    guard case .placeSent(let p) = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) else {
        Issue.record("not a place_sent")
        return
    }
    #expect([p.id, p.from, p.to, p.title] == ["p-1", "mac", "ipad", "Lexer.swift"])
    #expect(p.place == .object(["file": .object(["path": .string("/p/Lexer.swift"), "line": .number(27)])]))
    #expect(p.date == Date(timeIntervalSince1970: 1_760_000_300))
    // The app reads it back as its own type.
    struct File: Codable, Equatable { let path: String; let line: Int }
    struct Place: Codable, Equatable { let file: File }
    #expect(try p.place.decoded(as: Place.self) == Place(file: File(path: "/p/Lexer.swift", line: 27)))
    #expect(JSONValue(encoding: Place(file: File(path: "/p/Lexer.swift", line: 27))) == p.place)
}

@MainActor
@Test func theStoreKeepsTheDevicesAndHandsOnEachSentPlace() throws {
    let store = DuetStore()
    var heard: [String] = []
    store.onPlaceSent = { heard.append($0.id) }
    store.handle(.state(.connected(device: "mac")))
    store.handle(.devices([DeviceInfo(device: "ipad", online: true, kind: "ipad"), DeviceInfo(device: "mac", online: true, kind: "mac")]))
    #expect(store.devices.count == 2)
    #expect(store.otherDevices.map(\.device) == ["ipad"])
    let p = try JSONDecoder().decode(PlaceSent.self, from: Data(#"{"id":"p-2","from":"ipad","to":"mac","place":"anything","title":"Plan","ts":1}"#.utf8))
    store.handle(.placeSent(p))
    #expect(heard == ["p-2"])
    #expect(store.lastPlaceSent == p)
}

@MainActor
@Test func aNoteOnThePlanNamesTheConversationAndItsSteps() throws {
    let surface = NoteSurface.plan(conversationId: "c-1")
    let json = try JSONEncoder().encode(surface)
    #expect(try JSONSerialization.jsonObject(with: json) as? NSDictionary == ["kind": "plan", "conversationId": "c-1"])
    #expect(try JSONDecoder().decode(NoteSurface.self, from: json) == surface)
}

@Test func eachDeviceSaysWhatItHasOpenAndTheOneInFront() throws {
    let list = #"{"type":"devices","devices":[{"device":"ipad","online":false,"lastSeen":1760000200000,"kind":"ipad","open":{"places":[{"place":{"file":{"_0":"/p/Lexer.swift","line":27}},"title":"Lexer.swift"},{"place":{"diagram":{"_0":"g1"}},"title":"Lexer states"}],"current":1,"ts":1760000100000}},{"device":"mac","online":true,"kind":"mac"}]}"#
    guard case .devices(let devices) = try JSONDecoder().decode(ServerFrame.self, from: Data(list.utf8)) else {
        Issue.record("not a device list")
        return
    }
    let open = try #require(devices.first?.open)
    #expect(open.places.map(\.title) == ["Lexer.swift", "Lexer states"])
    #expect(open.current == 1 && open.ts == 1_760_000_100_000)
    #expect(open.places[1].place == .object(["diagram": .object(["_0": .string("g1")])]))
    #expect(devices.last?.open == nil, "the Mac never said")
}

@Test func aPlaceSentToWriteOnSaysSo() throws {
    let json = #"{"type":"place_sent","id":"p-3","from":"mac","to":"ipad","place":{"diagram":{"_0":"g1"}},"title":"Lexer states","ts":1,"write":true}"#
    guard case .placeSent(let p) = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) else {
        Issue.record("not a place_sent")
        return
    }
    #expect(p.write == true)
    let plain = try JSONDecoder().decode(PlaceSent.self, from: Data(#"{"id":"p-4","from":"mac","to":"ipad","place":"x","title":"x","ts":1}"#.utf8))
    #expect(plain.write == nil)
}
