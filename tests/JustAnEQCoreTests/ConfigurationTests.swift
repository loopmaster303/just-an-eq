import JustAnEQCore
import Testing

@Test func propertyNotificationsOnlyStopForRealChanges() {
    let stereo = StreamFormat(sampleRate: 48000, channels: 2)
    let start = AudioConfiguration(outputID: 7, nominalSampleRate: 48000,
                                   inputs: [stereo], outputs: [stereo], isAlive: true)
    #expect(!start.requiresStop(comparedTo: start))
    var current = start
    current.nominalSampleRate = 44100
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.inputs[0].channels = 1
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.outputs[0].flags = 8
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.outputs[0].sampleRate = 96000
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.outputs.append(stereo)
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.isAlive = false
    #expect(current.requiresStop(comparedTo: start))
    current = start
    current.outputID = 8
    #expect(current.requiresStop(comparedTo: start))
}

@Test func emptyBufferGraceExpiresAfterOneHundredMilliseconds() {
    #expect(ignoreStartupEmptyBuffer(isEmpty: true, startedAt: 1000, now: 99_001_000))
    #expect(!ignoreStartupEmptyBuffer(isEmpty: true, startedAt: 1000, now: 100_001_000))
    #expect(!ignoreStartupEmptyBuffer(isEmpty: false, startedAt: 1000, now: 1001))
    #expect(ignoreStartupEmptyBuffer(isEmpty: true, startedAt: 0, now: 10_000))
}
