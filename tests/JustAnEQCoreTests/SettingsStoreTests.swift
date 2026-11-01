import Foundation
import JustAnEQCore
import Testing
@testable import JustAnEQ

private func freshDefaults() -> UserDefaults {
    let name = "justaneq.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func settingsRoundTripThroughStore() {
    let defaults = freshDefaults()
    var settings = EQSettings()
    settings.balance = -0.25
    settings.boostDB = 4.5
    for index in 0..<10 { settings.bandDB[index] = Float(index) - 4.5 }
    SettingsStore(defaults: defaults).save(settings, preset: nil)
    let loaded = SettingsStore(defaults: defaults).load()
    #expect(loaded.settings == settings)
    #expect(loaded.preset == nil)

    SettingsStore(defaults: defaults).save(settings, preset: .bassFocus)
    #expect(SettingsStore(defaults: defaults).load().preset == .bassFocus)
}

@Test func missingOrCorruptStoreFallsBackToDefaults() {
    let defaults = freshDefaults()
    let empty = SettingsStore(defaults: defaults).load()
    #expect(empty.settings == EQSettings())
    #expect(empty.preset == .flat)
    defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
    let corrupt = SettingsStore(defaults: defaults).load()
    #expect(corrupt.settings == EQSettings())
    #expect(corrupt.preset == .flat)
}

@Test func decodingSanitisesBandCountRangeAndNonFinite() throws {
    let json = #"{"balance":5,"boostDB":99,"bandDB":[1,2,3,100,-100,0,0,0,0,0,7,8,9]}"#
    let settings = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
    #expect(settings.balance == 1)
    #expect(settings.boostDB == 12)
    #expect(settings.bandDB[3] == 12)
    #expect(settings.bandDB[4] == -12)
    #expect(settings.bandDB[10] == 0)
    let short = try JSONDecoder().decode(EQSettings.self, from: Data(#"{"balance":0,"boostDB":0,"bandDB":[1]}"#.utf8))
    #expect(short.bandDB[0] == 1 && short.bandDB[9] == 0)
    let nonFinite = try JSONDecoder().decode(
        EQSettings.self, from: Data(#"{"balance":"nan","boostDB":0,"bandDB":[]}"#.utf8))
    #expect(nonFinite.balance == 0)
}
