import JustAnEQCore
import Testing
@testable import JustAnEQ

@Test func menuIconReflectsOffOnAndError() {
    let off = menuIconName(isOn: false, hasError: false)
    let on = menuIconName(isOn: true, hasError: false)
    let error = menuIconName(isOn: false, hasError: true)
    #expect(Set([off, on, error]).count == 3)
    #expect(menuIconName(isOn: true, hasError: true) == error)
}

@Test func knobPutsZeroAtTwelveOClockAndRoundTrips() {
    let range = EQSettings.mixerRange
    #expect(RotaryKnob.fraction(of: 0, range: range) == 0.5)
    #expect(RotaryKnob.fraction(of: range.lowerBound, range: range) == 0)
    #expect(RotaryKnob.fraction(of: range.upperBound, range: range) == 1)
    for db: Float in [-26, -13, -3, 3, 6] {
        #expect(RotaryKnob.value(at: RotaryKnob.fraction(of: db, range: range), range: range) == db)
    }
    #expect(RotaryKnob.value(at: 0.51, range: range) == 0) // detent
}
