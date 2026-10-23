import Darwin
import Foundation
import WTVCore

/// Thread de tempo real que chama `onTick` a cada frame (D6): política de tempo constante,
/// `mach_wait_until` até t0 + N·duração, sem acumulação de erro.
public final class VideoClock: @unchecked Sendable {
    public struct Stats: Sendable {
        public var ticks: Int64 = 0
        public var lateTicks: Int64 = 0
        public var maxJitterMicros: Int64 = 0
        public init() {}
    }

    private let frameRate: FrameRate
    private let onTick: (Int64, UInt64) -> Void
    private var thread: Thread?
    private var running = false
    private var lock = os_unfair_lock()
    private var stats = Stats()
    private let timebase: mach_timebase_info_data_t

    public init(frameRate: FrameRate, onTick: @escaping (Int64, UInt64) -> Void) {
        self.frameRate = frameRate
        self.onTick = onTick
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
    }

    public var currentStats: Stats {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return stats
    }

    public func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [self] in self.loop() }
        t.name = "wtv.videoclock"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private let exited = DispatchSemaphore(value: 0)

    /// Pára e espera que a thread termine (evita dois relógios a chamar `onTick` ao mesmo tempo).
    public func stop() {
        guard thread != nil else { return }
        running = false
        _ = exited.wait(timeout: .now() + 1)
        thread = nil
    }

    private func nanosToAbs(_ ns: UInt64) -> UInt64 { ns * UInt64(timebase.denom) / UInt64(timebase.numer) }
    private func absToNanos(_ abs: UInt64) -> UInt64 { abs * UInt64(timebase.numer) / UInt64(timebase.denom) }

    private func applyRealtimePolicy(periodNanos: UInt64) {
        var policy = thread_time_constraint_policy(
            period: UInt32(nanosToAbs(periodNanos)),
            computation: UInt32(nanosToAbs(min(periodNanos / 4, 2_000_000))),
            constraint: UInt32(nanosToAbs(min(periodNanos / 2, 6_000_000))),
            preemptible: 1
        )
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), p, count)
            }
        }
    }

    private func loop() {
        let periodNanos = UInt64(frameRate.tickNanos(1))
        applyRealtimePolicy(periodNanos: periodNanos)
        let t0 = mach_absolute_time()
        var n: Int64 = 0
        while running {
            let deadlineAbs = t0 &+ nanosToAbs(UInt64(frameRate.tickNanos(n)))
            let now = mach_absolute_time()
            if now < deadlineAbs {
                mach_wait_until(deadlineAbs)
            } else if n > 0 {
                let lateNanos = absToNanos(now &- deadlineAbs)
                if lateNanos > periodNanos {
                    // Muito atrasado: salta frames em vez de os acumular.
                    let skipped = Int64(lateNanos / periodNanos)
                    n += skipped
                    os_unfair_lock_lock(&lock); stats.lateTicks += skipped; os_unfair_lock_unlock(&lock)
                    continue
                }
                os_unfair_lock_lock(&lock)
                stats.maxJitterMicros = max(stats.maxJitterMicros, Int64(lateNanos / 1000))
                os_unfair_lock_unlock(&lock)
            }
            let hostNanos = absToNanos(mach_absolute_time())
            onTick(n, hostNanos)
            os_unfair_lock_lock(&lock); stats.ticks += 1; os_unfair_lock_unlock(&lock)
            n += 1
        }
        exited.signal()
    }
}
