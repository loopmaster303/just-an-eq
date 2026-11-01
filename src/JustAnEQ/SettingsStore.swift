import Foundation
import JustAnEQCore

/// Persists EQ settings and the selected preset. Never stores the On/Off state.
struct SettingsStore {
    static let key = "justaneq.settings.v1"
    private struct Stored: Codable {
        var settings: EQSettings
        var preset: String?
    }

    var defaults: UserDefaults = .standard

    func load() -> (settings: EQSettings, preset: EQPreset?) {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return (EQSettings(), .flat) }
        return (stored.settings, stored.preset.flatMap(EQPreset.init(rawValue:)))
    }

    func save(_ settings: EQSettings, preset: EQPreset?) {
        guard let data = try? JSONEncoder().encode(Stored(settings: settings, preset: preset?.rawValue)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
