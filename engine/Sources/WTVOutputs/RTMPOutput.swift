import AVFoundation
import CoreMedia
import Foundation
import Logging
import RTMPHaishinKit
import WTVCore

/// Destino RTMP/RTMPS via HaishinKit 2.2.5. Recebe o bitstream já comprimido (passthrough verificado
/// em RTMPStream.append) e reconecta com backoff enquanto estiver "armado".
public final class RTMPOutput: StreamSink, @unchecked Sendable {
    public enum Status: Sendable, Equatable { case connecting, live, reconnecting(attempt: Int), stopped, error(String) }

    public let sinkId: String
    private let url: String        // rtmp://host/app
    private let streamKey: String
    private let connection = RTMPConnection()
    private var stream: RTMPStream?
    private var task: Task<Void, Never>?
    private var lock = os_unfair_lock()
    private var publishing = false
    private var armed = false
    private var waitingKey = true
    private var dropped = 0
    private var sentBytes: Int64 = 0
    /// Fila FIFO: um só consumidor chama `stream.append`, garantindo a ordem dos pacotes (vídeo e áudio).
    private enum Item { case video(CMSampleBuffer); case audio(AVAudioCompressedBuffer, AVAudioTime) }
    private var queueContinuation: AsyncStream<Item>.Continuation?
    private var consumer: Task<Void, Never>?
    private let log = Logger(label: "wtv.rtmp")
    public var onStatus: ((Status) -> Void)?

    public init(sinkId: String, url: String, streamKey: String) {
        self.sinkId = sinkId
        self.url = url
        self.streamKey = streamKey
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
        if let stream { _ = try? await stream.close() }
        try? await connection.close()
        onStatus?(.stopped)
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            os_unfair_lock_lock(&lock); let go = armed; os_unfair_lock_unlock(&lock)
            guard go else { return }
            onStatus?(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            do {
                let s = RTMPStream(connection: connection)
                stream = s
                _ = try await connection.connect(url)
                _ = try await s.publish(streamKey)
                os_unfair_lock_lock(&lock); publishing = true; waitingKey = true; os_unfair_lock_unlock(&lock)
                attempt = 0
                onStatus?(.live)
                log.info("RTMP a publicar em \(url)")
                // espera até a ligação cair
                for await status in await connection.status {
                    if status.code == RTMPConnection.Code.connectClosed.rawValue || status.code == RTMPConnection.Code.connectFailed.rawValue { break }
                }
                os_unfair_lock_lock(&lock); publishing = false; os_unfair_lock_unlock(&lock)
                try? await connection.close()
            } catch {
                os_unfair_lock_lock(&lock); publishing = false; os_unfair_lock_unlock(&lock)
                log.warning("RTMP: \(error)")
                onStatus?(.error("\(error)"))
                try? await connection.close()
            }
            os_unfair_lock_lock(&lock); let again = armed; os_unfair_lock_unlock(&lock)
            guard again, !Task.isCancelled else { return }
            attempt += 1
            let delay = min(10.0, 0.5 * pow(2, Double(min(attempt, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    public func sink(video sample: CMSampleBuffer, isKeyframe: Bool) {
        os_unfair_lock_lock(&lock)
        guard publishing, let stream else { os_unfair_lock_unlock(&lock); return }
        if waitingKey { if isKeyframe { waitingKey = false } else { dropped += 1; os_unfair_lock_unlock(&lock); return } }
        sentBytes += Int64(CMSampleBufferGetTotalSampleSize(sample))
        os_unfair_lock_unlock(&lock)
        _ = stream
        queueContinuation?.yield(.video(sample))
    }

    public func sink(audio sample: CMSampleBuffer, compressed: AVAudioCompressedBuffer, when: AVAudioTime) {
        os_unfair_lock_lock(&lock)
        guard publishing, !waitingKey, let stream else { os_unfair_lock_unlock(&lock); return }
        sentBytes += Int64(compressed.byteLength)
        os_unfair_lock_unlock(&lock)
        _ = stream
        queueContinuation?.yield(.audio(compressed, when))
    }

    public var stats: (bytes: Int64, dropped: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (sentBytes, dropped)
    }
}
