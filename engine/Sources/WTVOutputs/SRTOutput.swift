import AVFoundation
import CoreMedia
import Foundation
import Logging
import SRTHaishinKit
import WTVCore

/// Destino SRT (caller ou listener) via SRTHaishinKit: recebe o mesmo H.264/AAC já comprimido (MPEG-TS).
/// URL: `srt://host:porta?mode=caller&latency=120&passphrase=…` ou `srt://:porta?mode=listener`.
public final class SRTOutput: StreamSink, @unchecked Sendable {
    public enum Status: Sendable, Equatable { case connecting, live, reconnecting(attempt: Int), stopped, error(String) }

    public let sinkId: String
    private let url: URL
    private let connection = SRTConnection()
    private var stream: SRTStream?
    private var task: Task<Void, Never>?
    private var lock = os_unfair_lock()
    private var publishing = false
    private var armed = false
    private var waitingKey = true
    private var sentBytes: Int64 = 0
    private enum Item { case video(CMSampleBuffer); case audio(AVAudioCompressedBuffer, AVAudioTime) }
    private var queueContinuation: AsyncStream<Item>.Continuation?
    private var consumer: Task<Void, Never>?
    private let log = Logger(label: "wtv.srt")
    public var onStatus: ((Status) -> Void)?

    public init?(sinkId: String, url: String, latencyMs: Int?) {
        guard var comps = URLComponents(string: url), comps.scheme == "srt" else { return nil }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "mode" }) { items.append(URLQueryItem(name: "mode", value: comps.host?.isEmpty ?? true ? "listener" : "caller")) }
        if let latencyMs, !items.contains(where: { $0.name == "latency" }) { items.append(URLQueryItem(name: "latency", value: String(latencyMs))) }
        comps.queryItems = items
        guard let u = comps.url else { return nil }
        self.sinkId = sinkId
        self.url = u
    }

    public func start() {
        os_unfair_lock_lock(&lock); armed = true; os_unfair_lock_unlock(&lock)
        let (items, cont) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(256))
        queueContinuation = cont
        consumer = Task { [weak self] in
            for await item in items {
                guard let self, let stream = self.stream else { continue }
                switch item {
                case .video(let sb): await stream.append(sb)
                case .audio(let buf, let when): await stream.append(buf, when: when)
                }
            }
        }
        task = Task { await self.runLoop() }
    }

    public func stop() async {
        os_unfair_lock_lock(&lock); armed = false; publishing = false; os_unfair_lock_unlock(&lock)
        task?.cancel()
        queueContinuation?.finish()
        consumer?.cancel()
        await stream?.close()
        await connection.close()
        onStatus?(.stopped)
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            os_unfair_lock_lock(&lock); let go = armed; os_unfair_lock_unlock(&lock)
            guard go else { return }
            onStatus?(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            do {
                let s = SRTStream(connection: connection)
                stream = s
                try await connection.connect(url)
                await s.setExpectedMedias([.audio, .video])
                await s.publish()
                os_unfair_lock_lock(&lock); publishing = true; waitingKey = true; os_unfair_lock_unlock(&lock)
                attempt = 0
                onStatus?(.live)
                log.info("SRT a emitir para \(url.absoluteString)")
                while await connection.connected, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
                os_unfair_lock_lock(&lock); publishing = false; os_unfair_lock_unlock(&lock)
                await connection.close()
            } catch {
                os_unfair_lock_lock(&lock); publishing = false; os_unfair_lock_unlock(&lock)
                log.warning("SRT: \(error)")
                onStatus?(.error("\(error)"))
                await connection.close()
            }
            os_unfair_lock_lock(&lock); let again = armed; os_unfair_lock_unlock(&lock)
            guard again, !Task.isCancelled else { return }
            attempt += 1
            try? await Task.sleep(for: .seconds(min(10.0, 0.5 * pow(2, Double(min(attempt, 5))))))
        }
    }

    public func sink(video sample: CMSampleBuffer, isKeyframe: Bool) {
        os_unfair_lock_lock(&lock)
        guard publishing else { os_unfair_lock_unlock(&lock); return }
        if waitingKey { if isKeyframe { waitingKey = false } else { os_unfair_lock_unlock(&lock); return } }
        sentBytes += Int64(CMSampleBufferGetTotalSampleSize(sample))
        os_unfair_lock_unlock(&lock)
        queueContinuation?.yield(.video(sample))
    }

    public func sink(audio sample: CMSampleBuffer, compressed: AVAudioCompressedBuffer, when: AVAudioTime) {
        os_unfair_lock_lock(&lock)
        guard publishing, !waitingKey else { os_unfair_lock_unlock(&lock); return }
        sentBytes += Int64(compressed.byteLength)
        os_unfair_lock_unlock(&lock)
        queueContinuation?.yield(.audio(compressed, when))
    }

    public var stats: Int64 {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return sentBytes
    }
}
