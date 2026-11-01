/// HAL-independent snapshot for main-thread comparison. No notification should
/// stop playback unless the captured configuration actually changed.
public struct StreamFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: UInt32
    public var formatID: UInt32
    public var flags: UInt32
    public var bytesPerPacket: UInt32
    public var framesPerPacket: UInt32
    public var bytesPerFrame: UInt32
    public var bitsPerChannel: UInt32

    public init(sampleRate: Double, channels: UInt32, formatID: UInt32 = 0, flags: UInt32 = 0,
                bytesPerPacket: UInt32 = 0, framesPerPacket: UInt32 = 0,
                bytesPerFrame: UInt32 = 0, bitsPerChannel: UInt32 = 0) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.formatID = formatID
        self.flags = flags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.bitsPerChannel = bitsPerChannel
    }
}

public struct AudioConfiguration: Equatable, Sendable {
    public var outputID: UInt32
    public var nominalSampleRate: Double
    public var inputs: [StreamFormat]
    public var outputs: [StreamFormat]
    public var isAlive: Bool

    public init(outputID: UInt32, nominalSampleRate: Double, inputs: [StreamFormat],
                outputs: [StreamFormat], isAlive: Bool) {
        self.outputID = outputID
        self.nominalSampleRate = nominalSampleRate
        self.inputs = inputs
        self.outputs = outputs
        self.isAlive = isAlive
    }

    public func requiresStop(comparedTo start: AudioConfiguration) -> Bool {
        !isAlive || outputID != start.outputID || nominalSampleRate != start.nominalSampleRate ||
        inputs != start.inputs || outputs != start.outputs
    }
}

/// Before Start returns, startedAt is zero; afterward the grace is wall-clock
/// based, never extended by additional empty callbacks or lack of audio frames.
public func ignoreStartupEmptyBuffer(isEmpty: Bool, startedAt: UInt64, now: UInt64) -> Bool {
    isEmpty && (startedAt == 0 || (now >= startedAt && now - startedAt < 100_000_000))
}
