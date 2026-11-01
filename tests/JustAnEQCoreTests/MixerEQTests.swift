import Foundation
import JustAnEQCore
import Testing

private func gainDB(_ frequency: Double, _ settings: EQSettings) -> Double {
    20 * log10(renderTone(frequency: frequency, settings: settings).0 / renderTone(frequency: frequency, settings: EQSettings()).0)
}

private func mixer(_ band: Int, _ db: Float) -> EQSettings {
    var settings = EQSettings()
    settings.mode = .mixer
    settings.mixerDB[band] = db
    return settings
}

// LF shelf, Lo-Mid peak, Hi-Mid peak, HF shelf, probed where each band is at full gain.
private let probes: [Double] = [30, 400, 2500, 16000]

@Test func eachMixerBandBoostsAndNearlyKillsItsRange() {
    for band in 0..<4 {
        #expect(abs(gainDB(probes[band], mixer(band, 6)) - 6) < 0.6)
        #expect(gainDB(probes[band], mixer(band, -26)) < -20)
    }
}

@Test func mixerBandsLeaveDistantRangesAlone() {
    #expect(abs(gainDB(10000, mixer(0, -26))) < 0.5)
    #expect(abs(gainDB(40, mixer(3, -26))) < 0.5)
}

@Test func modeSelectsWhichBandSetIsActive() {
    var settings = EQSettings()
    settings.bandDB[5] = 6
    settings.mixerDB[0] = -26
    settings.mode = .mixer
    #expect(abs(gainDB(1000, settings)) < 0.5)
    settings.mode = .graphic
    #expect(abs(gainDB(30, settings)) < 0.5)
    #expect(abs(gainDB(1000, settings) - 6) < 0.1)
}

@Test func mixerSettingsPersistAndOldDataDecodesAsGraphic() throws {
    var settings = mixer(2, -10)
    settings.mixerDB[3] = 5
    let decoded = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    let old = try JSONDecoder().decode(EQSettings.self, from: Data(#"{"balance":0,"boostDB":0,"bandDB":[]}"#.utf8))
    #expect(old.mode == .graphic && old.mixerDB == SIMD4(repeating: 0))
    let wild = try JSONDecoder().decode(EQSettings.self,
        from: Data(#"{"balance":0,"boostDB":0,"bandDB":[],"mode":"bogus","mixerDB":[99,-99]}"#.utf8))
    #expect(wild.mode == .graphic)
    #expect(wild.mixerDB[0] == 6 && wild.mixerDB[1] == -26 && wild.mixerDB[2] == 0)
}
