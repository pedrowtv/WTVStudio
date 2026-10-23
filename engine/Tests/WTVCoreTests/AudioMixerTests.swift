import Foundation
import Testing
import WTVAudio
import WTVProtocol

private func state() -> EngineState {
    var s = EngineState(system: SystemState(engineVersion: "t", pid: 1, startedAt: Date(timeIntervalSince1970: 0), bind: "x", remoteAccess: false))
    s.inputs["a"] = InputState(id: "a", kind: .synthetic, name: "Bars", config: .object(["pattern": .string("bars")]))
    s.inputs["b"] = InputState(id: "b", kind: .synthetic, name: "Sync", config: .object(["pattern": .string("sync")]))
    s.inputOrder = ["a", "b"]
    s.audio.inputs["a"] = AudioChannelState()
    s.audio.inputs["b"] = AudioChannelState()
    s.program.inputId = "a"
    s.preview.inputId = "b"
    return s
}

@Suite struct MixPlanTests {
    @Test func generatorsFromConfig() {
        let p = MixPlan(state: state(), transitionProgress: 0)
        guard case .tone = p.channels["a"]?.generator else { Issue.record("barras sem tom"); return }
        guard case .beep = p.channels["b"]?.generator else { Issue.record("sync sem beep"); return }
        #expect(p.channels["a"]?.programWeight == 1)
        #expect(p.channels["b"]?.programWeight == 0)
    }

    @Test func afvFollowsTransition() {
        var s = state()
        s.program.transition = TransitionState(kind: "fade", durationFrames: 25)
        let p = MixPlan(state: s, transitionProgress: 0.25)
        #expect(p.channels["a"]?.programWeight == 0.75)
        #expect(p.channels["b"]?.programWeight == 0.25)
    }

    @Test func ftbSilencesProgram() {
        var s = state()
        s.program.ftb = true
        let p = MixPlan(state: s, transitionProgress: 0)
        #expect(p.channels["a"]?.programWeight == 0)
    }

    @Test func gainAndSolo() {
        var s = state()
        s.audio.inputs["a"]?.db = -6
        s.audio.inputs["b"]?.solo = true
        let p = MixPlan(state: s, transitionProgress: 0)
        #expect(abs((p.channels["a"]?.gain ?? 0) - 0.5012) < 0.001)
        #expect(p.anySolo)
        #expect(MixPlan.linear(db: -60) == 0)
        #expect(MixPlan.linear(db: 0) == 1)
    }
}

@Suite struct MeterFrameTests {
    @Test func encodesCountAndMaster() {
        let m = AudioMixer()
        let data = m.metersFrame(order: ["a", "b"])
        #expect(data.count == 2 + 5 * 9)   // 2 fontes + Bus B + Bus A + Master
        #expect(data[0] == 5 && data[1] == 0)
        #expect(data[2] == 0)          // índice da fonte a
        #expect(data[2 + 9] == 1)      // fonte b
        #expect(data[2 + 18] == 253)   // Bus B
        #expect(data[2 + 27] == 254)   // Bus A
        #expect(data[2 + 36] == 255)   // Master
    }

    @Test func float16RoundTrip() {
        let bits = AudioMixer.float16(0.25)
        #expect(Float(Float16(bitPattern: bits)) == 0.25)
        #expect(AudioMixer.float16(-1) == Float16(0).bitPattern)
    }
}
