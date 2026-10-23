import Foundation

// Espelho Swift de packages/protocol/src/types.ts. Manter os dois em sincronia.

public let protocolVersion = 1
public let defaultPort = 7420

public typealias InputId = String
public typealias OutputId = String

public struct Raster: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double

    public init(width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public static let hd50 = Raster(width: 1920, height: 1080, fps: 50)
    public static let hd60 = Raster(width: 1920, height: 1080, fps: 60)
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public static let full = Rect(x: 0, y: 0, w: 1, h: 1)
}

public enum InputKind: String, Codable, Sendable {
    case synthetic, media, image, title, camera, screen, ndi, srt, decklink
}

public enum InputStatus: String, Codable, Sendable {
    case idle, starting, live, noSignal, error
}

public struct VideoFormat: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var pixelFormat: String
    public init(width: Int, height: Int, fps: Double, pixelFormat: String) {
        self.width = width; self.height = height; self.fps = fps; self.pixelFormat = pixelFormat
    }
}

public struct ColourAdjust: Codable, Sendable, Equatable {
    public var brightness = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    public init() {}
}

public struct MediaTransport: Codable, Sendable, Equatable {
    public var durationSeconds: Double
    public var positionSeconds: Double
    public var state: String
    public var loop: Bool
    public var inSeconds: Double?
    public var outSeconds: Double?
    public init(durationSeconds: Double, positionSeconds: Double = 0, state: String = "stopped", loop: Bool = false) {
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
        self.state = state
        self.loop = loop
    }
}

public struct InputState: Codable, Sendable, Equatable {
    public var id: InputId
    public var kind: InputKind
    public var name: String
    public var status: InputStatus
    public var statusCode: String?
    public var format: VideoFormat?
    public var latencyFrames: Int
    public var videoDelayFrames: Int
    public var fit: String
    public var colour: ColourAdjust
    public var lowBandwidth: Bool
    public var config: JSONValue
    public var media: MediaTransport?
    public var hasAudio: Bool

    public init(id: InputId, kind: InputKind, name: String, config: JSONValue, hasAudio: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = .idle
        self.latencyFrames = kind == .ndi || kind == .srt ? 3 : (kind == .synthetic ? 0 : 1)
        self.videoDelayFrames = 0
        self.fit = "fit"
        self.colour = ColourAdjust()
        self.lowBandwidth = false
        self.config = config
        self.hasAudio = hasAudio
    }
}

public struct WipeSpec: Codable, Sendable, Equatable {
    public var direction: String
    public var softness: Double
    public init(direction: String, softness: Double) { self.direction = direction; self.softness = softness }
}

public struct TransitionState: Codable, Sendable, Equatable {
    public var kind: String
    public var durationFrames: Int
    public var progress: Double
    public var auto: Bool
    public var wipe: WipeSpec?
    public var colour: String?
    public init(kind: String, durationFrames: Int, progress: Double = 0, auto: Bool = true, wipe: WipeSpec? = nil, colour: String? = nil) {
        self.kind = kind; self.durationFrames = durationFrames; self.progress = progress; self.auto = auto; self.wipe = wipe; self.colour = colour
    }
}

public struct Border: Codable, Sendable, Equatable {
    public var width: Double
    public var colour: String
    public init(width: Double, colour: String) { self.width = width; self.colour = colour }
}

public struct OverlayTransition: Codable, Sendable, Equatable {
    public var kind: String
    public var durationFrames: Int
    public init(kind: String = "fade", durationFrames: Int = 12) { self.kind = kind; self.durationFrames = durationFrames }
}

public struct OverlaySlot: Codable, Sendable, Equatable {
    public var inputId: InputId?
    public var on: Bool
    public var rect: Rect
    public var crop: Rect
    public var opacity: Double
    public var border: Border?
    public var transition: OverlayTransition

    public init() {
        inputId = nil
        on = false
        rect = Rect(x: 0.65, y: 0.05, w: 0.3, h: 0.3)
        crop = .full
        opacity = 1
        border = nil
        transition = OverlayTransition()
    }
}

public struct AudioPluginState: Codable, Sendable, Equatable {
    public var id: String
    public var componentId: String
    public var name: String
    public var bypass = false
    public init(id: String, componentId: String, name: String) { self.id = id; self.componentId = componentId; self.name = name }
}

public struct AudioChannelState: Codable, Sendable, Equatable {
    public var db = 0.0
    public var mute = false
    public var solo = false
    public var afv = false
    public var pan = 0.0
    public var delayMs = 0
    public var channels = 2
    /// Barramentos a que o canal envia: "master", "a", "b".
    public var buses: [String] = ["master"]
    /// Cadeia de plugins Audio Unit, por ordem.
    public var plugins: [AudioPluginState] = []
    public init() {}
}

public struct AudioMaster: Codable, Sendable, Equatable {
    public var db = 0.0
    public var mute = false
    public var limiter = true
    public init() {}
}

public struct AudioMonitor: Codable, Sendable, Equatable {
    public var deviceId: String?
    public var db = 0.0
    /// Barramento ouvido no dispositivo de monitorização: "master", "a" ou "b".
    public var bus = "master"
    public init() {}
}

public struct AudioState: Codable, Sendable, Equatable {
    public var inputs: [InputId: AudioChannelState] = [:]
    public var master = AudioMaster()
    public var monitor = AudioMonitor()
    /// Barramento por saída: "stream" (RTMP/SRT/gravação) e "ndi".
    public var outputBus: [String: String] = ["stream": "master", "ndi": "master"]
    public init() {}
}

public struct AudioUnitDevice: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var manufacturer: String
    public init(id: String, name: String, manufacturer: String) { self.id = id; self.name = name; self.manufacturer = manufacturer }
}

public enum OutputKind: String, Codable, Sendable { case rtmp, srt, ndi }
public enum OutputStatus: String, Codable, Sendable { case stopped, starting, live, reconnecting, error }

public struct OutputConfig: Codable, Sendable, Equatable {
    public var url: String?
    public var hasStreamKey: Bool?
    public var ndiName: String?
    public var latencyMs: Int?
    public init(url: String? = nil, hasStreamKey: Bool? = nil, ndiName: String? = nil, latencyMs: Int? = nil) {
        self.url = url; self.hasStreamKey = hasStreamKey; self.ndiName = ndiName; self.latencyMs = latencyMs
    }
}

public struct OutputState: Codable, Sendable, Equatable {
    public var id: OutputId
    public var kind: OutputKind
    public var name: String
    public var status: OutputStatus
    public var statusCode: String?
    public var profileId: String
    public var config: OutputConfig
    public var autoRestart: Bool
    public var startedAt: Date?

    public init(id: OutputId, kind: OutputKind, name: String, profileId: String = "program", config: OutputConfig) {
        self.id = id; self.kind = kind; self.name = name; self.status = .stopped
        self.profileId = profileId; self.config = config; self.autoRestart = false
    }
}

public struct RecordingState: Codable, Sendable, Equatable {
    public var status = "idle"
    public var file: String?
    public var startedAt: Date?
    public var bytes: Int?
    public var container = "mov"
    /// Pasta de destino (nil = ~/Movies/WTV Studio). Persistida em session.json.
    public var folder: String?
    public init() {}
}

public struct ProjectorState: Codable, Sendable, Equatable {
    public var displayId: String?
    public var source = "program"
    public var fullscreen = true
    public init() {}
}

public struct Tile: Codable, Sendable, Equatable {
    public var source: String
    public var rect: Rect
    public var label: String
    public init(source: String, rect: Rect, label: String) { self.source = source; self.rect = rect; self.label = label }
}

public struct MultiviewState: Codable, Sendable, Equatable {
    public var layoutId = "2+8"
    public var size = Size(width: 1280, height: 720)
    public var tiles: [Tile] = []
    public init() {}
}

public struct Size: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct VideoDeviceFormat: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: [Double]
    public var pixelFormat: String
    public init(width: Int, height: Int, fps: [Double], pixelFormat: String) {
        self.width = width; self.height = height; self.fps = fps; self.pixelFormat = pixelFormat
    }
}

public struct VideoDevice: Codable, Sendable, Equatable {
    public var uniqueId: String
    public var name: String
    public var kind: String
    public var formats: [VideoDeviceFormat]
    public init(uniqueId: String, name: String, kind: String, formats: [VideoDeviceFormat]) {
        self.uniqueId = uniqueId; self.name = name; self.kind = kind; self.formats = formats
    }
}

public struct AudioDevice: Codable, Sendable, Equatable {
    public var uid: String
    public var name: String
    public var channels: Int
    public var sampleRate: Double
    public var isDefault: Bool
    public init(uid: String, name: String, channels: Int, sampleRate: Double, isDefault: Bool) {
        self.uid = uid; self.name = name; self.channels = channels; self.sampleRate = sampleRate; self.isDefault = isDefault
    }
}

public struct Display: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshHz: Double
    public var isMain: Bool
    public init(id: String, name: String, width: Int, height: Int, refreshHz: Double, isMain: Bool) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.refreshHz = refreshHz; self.isMain = isMain
    }
}

public struct NdiSource: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct Devices: Codable, Sendable, Equatable {
    public var video: [VideoDevice] = []
    public var audioIn: [AudioDevice] = []
    public var audioOut: [AudioDevice] = []
    public var displays: [Display] = []
    public var ndiSources: [NdiSource] = []
    public var audioUnits: [AudioUnitDevice] = []
    public init() {}
}

public struct Budget: Codable, Sendable, Equatable {
    public var encoderCapacity1080pFps = 200.0
    public var encoderUsedPercent = 0.0
    public var memoryUsedMB = 0.0
    public var memoryLimitMB = 1800.0
    public init() {}
}

public struct Alarm: Codable, Sendable, Equatable {
    public var id: String
    public var code: String
    public var level: String
    public var at: Date
    public var detail: String?
    public init(id: String = UUID().uuidString, code: String, level: String, at: Date = Date(), detail: String? = nil) {
        self.id = id; self.code = code; self.level = level; self.at = at; self.detail = detail
    }
}

public struct SystemState: Codable, Sendable, Equatable {
    public var engineVersion: String
    public var pid: Int
    public var startedAt: Date
    public var bind: String
    public var remoteAccess: Bool
    public var thermal: String
    public init(engineVersion: String, pid: Int, startedAt: Date, bind: String, remoteAccess: Bool, thermal: String = "nominal") {
        self.engineVersion = engineVersion; self.pid = pid; self.startedAt = startedAt
        self.bind = bind; self.remoteAccess = remoteAccess; self.thermal = thermal
    }
}

public struct ProgramState: Codable, Sendable, Equatable {
    public var inputId: InputId?
    public var transition: TransitionState?
    public var ftb = false
    public init() {}
}

public struct PreviewState: Codable, Sendable, Equatable {
    public var inputId: InputId?
    public init() {}
}

public struct Project: Codable, Sendable, Equatable {
    public var name: String
    public var raster: Raster
    public var path: String?
    public init(name: String, raster: Raster, path: String? = nil) { self.name = name; self.raster = raster; self.path = path }
}

public struct EngineState: Codable, Sendable, Equatable {
    public var rev: Int
    public var project: Project
    public var inputs: [InputId: InputState]
    public var inputOrder: [InputId]
    public var program: ProgramState
    public var preview: PreviewState
    public var overlays: [OverlaySlot]
    public var audio: AudioState
    public var outputs: [OutputId: OutputState]
    public var recording: RecordingState
    public var projector: ProjectorState
    public var multiview: MultiviewState
    public var devices: Devices
    public var permissions: [String: String]
    public var budget: Budget
    public var alarms: [Alarm]
    public var system: SystemState

    public init(system: SystemState, raster: Raster = .hd50) {
        rev = 0
        project = Project(name: "Sem título", raster: raster)
        inputs = [:]
        inputOrder = []
        program = ProgramState()
        preview = PreviewState()
        overlays = [OverlaySlot(), OverlaySlot(), OverlaySlot(), OverlaySlot()]
        audio = AudioState()
        outputs = [:]
        recording = RecordingState()
        projector = ProjectorState()
        multiview = MultiviewState()
        devices = Devices()
        permissions = ["camera": "unknown", "microphone": "unknown", "screen": "unknown", "localNetwork": "unknown"]
        budget = Budget()
        alarms = []
        self.system = system
    }
}
