import Testing
import JustAnEQCore

@Test func stereoIdentityPreservesSamplesAndBounds() {
    let input: [Float] = [-1, 1, -0.25, 0.75, 0, -0.0, .leastNormalMagnitude, .greatestFiniteMagnitude]
    var output = [Float](repeating: 42, count: input.count + 2)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!.advanced(by: 1), frames: 4)
        }
    }
    #expect(Array(output[1...input.count]).map(\.bitPattern) == input.map(\.bitPattern))
    #expect(output.first == 42)
    #expect(output.last == 42)
}

@Test func zeroFramesLeavesOutputUntouched() {
    var input: Float = 1
    var output: Float = 42
    process(&input, &output, frames: 0)
    #expect(output == 42)
}

