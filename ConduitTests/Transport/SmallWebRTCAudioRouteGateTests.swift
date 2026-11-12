//
//  SmallWebRTCAudioRouteGateTests.swift
//  ConduitTests
//
//  The rules the SmallWebRTC transport picks the SDK's preferred device by: the
//  route at the first attach is kept, a join before it takes the session's route
//  provisionally (the loudspeaker as the earpiece), the engine's request wins at
//  once and for later clients, a headset that appears is followed and one that
//  goes falls back, every new client is given the route again, and a refused
//  change is asked for again.
//

import AVFoundation
import Testing
@testable import Conduit

struct SmallWebRTCAudioRouteGateTests {

    private func attachedGate(on route: SmallWebRTCAudioRoute?, devices: Set<SmallWebRTCAudioRoute> = [.earpiece, .speaker]) -> SmallWebRTCAudioRouteGate {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        gate.attach(activeRoute: route, devices: devices)
        return gate
    }

    @Test(arguments: [
        (AVAudioSession.Port.builtInReceiver, SmallWebRTCAudioRoute.earpiece),
        (.builtInSpeaker, .speaker),
        (.bluetoothHFP, .bluetooth), (.bluetoothA2DP, .bluetooth), (.bluetoothLE, .bluetooth),
        (.headphones, .wired), (.headsetMic, .wired),
    ])
    func namesTheOutputPortsItCanGiveTheSDK(port: AVAudioSession.Port, route: SmallWebRTCAudioRoute) {
        #expect(SmallWebRTCAudioRoute(outputPort: port) == route)
    }

    @Test(arguments: [AVAudioSession.Port.carAudio, .airPlay, .usbAudio, .HDMI])
    func leavesOtherOutputPortsToTheSDK(port: AVAudioSession.Port) {
        #expect(SmallWebRTCAudioRoute(outputPort: port) == nil)
    }

    @Test(arguments: SmallWebRTCAudioRoute.allCases)
    func theSDKsDeviceIDsRoundTrip(route: SmallWebRTCAudioRoute) {
        #expect(SmallWebRTCAudioRoute(deviceID: route.deviceID) == route)
    }

    @Test func theSDKsDeviceIDsAreItsOwn() {
        #expect(SmallWebRTCAudioRoute.allCases.map(\.deviceID) == ["earpiece", "speakerphone", "bluetooth", "wired"])
    }

    @Test(arguments: SmallWebRTCAudioRoute.allCases)
    func theFirstAttachKeepsTheCallsRoute(route: SmallWebRTCAudioRoute) {
        var gate = attachedGate(on: route)
        #expect(gate.wanted == route)
        let next = gate.beginApplying()
        #expect(next == .init(route: route, session: 1))
        let following = gate.beginApplying()
        #expect(following == nil) // given once
    }

    @Test func nothingIsGivenBeforeAnyRouteIsKnown() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        let next = gate.beginApplying()
        #expect(next == nil)
    }

    @Test func aRouteItCannotNameIsLeftToTheSDK() {
        var gate = attachedGate(on: nil)
        #expect(gate.wanted == nil)
        let next = gate.beginApplying()
        #expect(next == nil)
    }

    @Test func aLaterAttachKeepsTheFirstRoute() {
        var gate = attachedGate(on: .earpiece)
        let wasFirst = gate.attach(activeRoute: .speaker, devices: [.speaker]) // after a hold
        #expect(!wasFirst)
        #expect(gate.wanted == .earpiece)
    }

    @Test(arguments: [
        (SmallWebRTCAudioRoute.earpiece, SmallWebRTCAudioRoute.earpiece),
        (.speaker, .earpiece),
        (.bluetooth, .bluetooth),
        (.wired, .wired),
    ])
    func aJoinBeforeTheFirstAttachTakesTheSessionsRouteProvisionally(session: SmallWebRTCAudioRoute, provisional: SmallWebRTCAudioRoute) {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        gate.joinWillStart(activeRoute: session)

        #expect(gate.wanted == provisional)
        #expect(gate.isFollowedRouteProvisional)
        let next = gate.beginApplying()
        #expect(next == .init(route: provisional, session: 1))
    }

    @Test func theFirstAttachReplacesAProvisionalRoute() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        gate.joinWillStart(activeRoute: .earpiece)
        _ = gate.beginApplying()

        gate.attach(activeRoute: .bluetooth, devices: [.earpiece, .speaker, .bluetooth])

        #expect(!gate.isFollowedRouteProvisional)
        let next = gate.beginApplying()
        #expect(next == .init(route: .bluetooth, session: 1))
    }

    @Test func aFirstAttachOnARouteItCannotNameClearsAProvisionalOne() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        gate.joinWillStart(activeRoute: .earpiece)
        _ = gate.beginApplying()

        gate.attach(activeRoute: nil, devices: [])

        #expect(gate.wanted == nil)
        let next = gate.beginApplying()
        #expect(next == .init(route: nil, session: 1)) // the SDK's own choice again
        let following = gate.beginApplying()
        #expect(following == nil)
    }

    @Test func aJoinAfterTheFirstAttachKeepsItsRoute() {
        var gate = attachedGate(on: .earpiece)
        gate.joinWillStart(activeRoute: .speaker)
        #expect(gate.wanted == .earpiece)
    }

    @Test func aJoinWithNoReadableRouteTakesNone() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.joinWillStart(activeRoute: nil)
        #expect(gate.wanted == nil)
    }

    @Test func theEnginesRequestWinsBeforeAnyAttach() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.sessionDidReset()
        gate.engineDidRequest(.speaker)
        gate.joinWillStart(activeRoute: .earpiece)

        #expect(gate.wanted == .speaker)
        #expect(gate.wantedReason == "engine request")
        let next = gate.beginApplying()
        #expect(next == .init(route: .speaker, session: 1))
    }

    @Test func theEnginesRequestWinsOverTheCallsRoute() {
        var gate = attachedGate(on: .earpiece)
        _ = gate.beginApplying()

        gate.engineDidRequest(.speaker)
        let next = gate.beginApplying()
        #expect(next == .init(route: .speaker, session: 1))

        gate.attach(activeRoute: .earpiece, devices: []) // a hold ends
        #expect(gate.wanted == .speaker)
        let following = gate.beginApplying()
        #expect(following == nil)
    }

    @Test func everyNewClientIsGivenTheRouteAgain() {
        var gate = attachedGate(on: .earpiece)
        _ = gate.beginApplying()

        gate.sessionDidReset() // a reconnect's new client, or a session taken over
        let next = gate.beginApplying()
        #expect(next == .init(route: .earpiece, session: 2))
    }

    @Test func aRefusedChangeIsAskedForAgainAtTheNextTrigger() throws {
        var gate = attachedGate(on: .earpiece)
        let first = gate.beginApplying()
        let application = try #require(first)

        gate.applyDidFail(application)
        let next = gate.beginApplying()
        #expect(next == application)
    }

    @Test func aRefusalForAnOldClientChangesNothing() throws {
        var gate = attachedGate(on: .earpiece)
        let first = gate.beginApplying()
        let old = try #require(first)
        gate.sessionDidReset()
        _ = gate.beginApplying()

        gate.applyDidFail(old)
        let next = gate.beginApplying()
        #expect(next == nil)
    }

    @Test(arguments: [SmallWebRTCAudioRoute.bluetooth, .wired])
    func aHeadsetThatAppearsIsFollowed(headset: SmallWebRTCAudioRoute) {
        var gate = attachedGate(on: .earpiece)
        _ = gate.beginApplying()

        gate.devicesDidChange([.earpiece, .speaker, headset])

        #expect(gate.wanted == headset)
        let next = gate.beginApplying()
        #expect(next == .init(route: headset, session: 1))
    }

    @Test func devicesAlreadyThereAtTheFirstListMoveNothing() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.attach(activeRoute: .earpiece, devices: [])
        gate.devicesDidChange([.earpiece, .speaker, .bluetooth]) // the baseline
        #expect(gate.wanted == .earpiece)
    }

    @Test func anEmptyDeviceListIsIgnored() {
        var gate = attachedGate(on: .bluetooth, devices: [.bluetooth, .earpiece, .speaker])
        gate.devicesDidChange([])
        #expect(gate.wanted == .bluetooth)
        #expect(gate.knownDevices == [.bluetooth, .earpiece, .speaker])
    }

    @Test func whenTheFollowedHeadsetGoesTheCallReturnsToTheEarpiece() {
        var gate = attachedGate(on: .bluetooth, devices: [.bluetooth, .earpiece, .speaker])
        gate.devicesDidChange([.earpiece, .speaker])
        #expect(gate.wanted == .earpiece)
    }

    @Test func whenTheFollowedHeadsetGoesAnotherStillThereIsFollowed() {
        // The SDK hides the earpiece and Bluetooth while a wired headset is in.
        var gate = attachedGate(on: .wired, devices: [.wired, .speaker])
        gate.devicesDidChange([.bluetooth, .earpiece, .speaker])
        #expect(gate.wanted == .bluetooth)
    }

    @Test func withNoEarpieceTheCallFallsBackToTheSpeaker() {
        var gate = attachedGate(on: .bluetooth, devices: [.bluetooth, .speaker])
        gate.devicesDidChange([.speaker])
        #expect(gate.wanted == .speaker)
    }

    @Test func anEngineRequestIsNotMovedByDevices() {
        var gate = attachedGate(on: .earpiece)
        gate.engineDidRequest(.speaker)
        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])
        #expect(gate.wanted == .speaker)
    }

    @Test func aProvisionalRouteFollowsAHeadsetToo() {
        var gate = SmallWebRTCAudioRouteGate()
        gate.joinWillStart(activeRoute: .earpiece)
        gate.devicesDidChange([.earpiece, .speaker]) // the join's first list
        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])
        #expect(gate.wanted == .bluetooth)
    }
}
