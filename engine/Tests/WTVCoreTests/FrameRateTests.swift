import Testing
import WTVCore

@Suite struct FrameRateTests {
    @Test func exactTicks5994() {
        let fr = FrameRate(fps: 59.94)!
        // 60000 ticks = 1001 segundos exactos
        #expect(fr.tickNanos(60000) == 1001 * 1_000_000_000)
        // 5 frames = 4004 amostras a 48 kHz
        #expect(fr.sampleIndex(forTick: 5) == 4004)
        #expect(fr.sampleIndex(forTick: 60000) == 1001 * 48000)
    }

    @Test func noDriftOverADay() {
        let fr = FrameRate(fps: 29.97)!
        let frames: Int64 = 30000 * 86400 // um dia a 29.97 em ticks
        #expect(fr.tickNanos(frames) == 86400 * 1001 * 1_000_000_000)
    }

    @Test func integerRates() {
        #expect(FrameRate(fps: 50)!.tickNanos(50) == 1_000_000_000)
        #expect(FrameRate(fps: 25)!.sampleIndex(forTick: 1) == 1920)
        #expect(FrameRate(fps: 60)!.sampleIndex(forTick: 1) == 800)
        #expect(FrameRate(fps: 24) == nil)
    }

    @Test func tickAtTime() {
        let fr = FrameRate(fps: 50)!
        #expect(fr.tick(atNanos: 19_999_999) == 0)
        #expect(fr.tick(atNanos: 20_000_000) == 1)
        #expect(fr.tick(atNanos: 1_000_000_000) == 50)
    }
}
