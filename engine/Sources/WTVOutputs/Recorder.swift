import AVFoundation
import CoreMedia
import Foundation
import WTVCore

/// Gravação passthrough do bitstream do Program (D15): .mov fragmentado a cada segundo,
/// por isso um crash deixa um ficheiro legível até ao último fragmento.
public final class Recorder: StreamSink, @unchecked Sendable {
    public let sinkId: String
    public let url: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "wtv.recorder")
    private var started = false
    private var failed = false
    private var bytesWritten: Int64 = 0
    private var startPTS: CMTime = .invalid
    private var waitingKey = false
    public var onError: ((String) -> Void)?

    public init(sinkId: String, url: URL) {
        self.sinkId = sinkId
        self.url = url
    }

    public func sink(video sample: CMSampleBuffer, isKeyframe: Bool) {
        queue.async { [self] in
            guard !failed else { return }
            if writer == nil {
                guard isKeyframe, let desc = CMSampleBufferGetFormatDescription(sample) else { return }
                do { try open(videoFormat: desc, firstPTS: CMSampleBufferGetPresentationTimeStamp(sample)) } catch { fail("RECORD_OPEN: \(error)"); return }
            }
            guard let writer, let videoInput, started else { return }
            if !videoInput.isReadyForMoreMediaData {
                // Não se pode perder um P-frame em passthrough: salta até ao próximo keyframe.
                waitingKey = true
                return
            }
            if waitingKey { guard isKeyframe else { return }; waitingKey = false }
            if !videoInput.append(sample) { fail("RECORD_WRITE: \(writer.error?.localizedDescription ?? "?")") }
            bytesWritten += Int64(CMSampleBufferGetTotalSampleSize(sample))
        }
    }

    public func sink(audio sample: CMSampleBuffer, compressed: AVAudioCompressedBuffer, when: AVAudioTime) {
        queue.async { [self] in
            guard !failed, started, let writer, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= startPTS else { return } // áudio anterior ao 1.º frame
            if !audioInput.append(sample) { fail("RECORD_WRITE_AUDIO: \(writer.error?.localizedDescription ?? "?")") }
            bytesWritten += Int64(CMSampleBufferGetTotalSampleSize(sample))
        }
    }

    /// Formato de áudio conhecido antecipadamente (o AAC é sempre 48 kHz estéreo); recebido do codificador.
    public var audioFormatHint: CMFormatDescription?

    private func open(videoFormat: CMFormatDescription, firstPTS: CMTime) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        w.shouldOptimizeForNetworkUse = false
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw RecorderError.cannotAdd("vídeo") }
        w.add(v)
        if let hint = audioFormatHint {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); audioInput = a }
        }
        guard w.startWriting() else { throw RecorderError.cannotAdd(w.error?.localizedDescription ?? "startWriting") }
        startPTS = firstPTS
        w.startSession(atSourceTime: firstPTS)
        writer = w
        videoInput = v
        started = true
    }

    public func stop(completion: @escaping (Int64) -> Void) {
        queue.async { [self] in
            guard let writer, started else { completion(0); return }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let bytes = bytesWritten
            writer.finishWriting { completion(bytes) }
            self.writer = nil
            started = false
        }
    }

    public var bytes: Int64 { queue.sync { bytesWritten } }

    private func fail(_ code: String) {
        failed = true
        onError?(code)
    }
}

public enum RecorderError: Error, CustomStringConvertible {
    case cannotAdd(String)
    public var description: String { if case .cannotAdd(let s) = self { return "AVAssetWriter: \(s)" }; return "" }
}
