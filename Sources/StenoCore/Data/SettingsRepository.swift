import Foundation

public final class SettingsRepository: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "ambient.recorder.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RecorderSettings {
        guard let data = defaults.data(forKey: key) else {
            return RecorderSettings()
        }

        do {
            return try JSONDecoder().decode(RecorderSettings.self, from: data).validated()
        } catch {
            return RecorderSettings()
        }
    }

    public func save(_ settings: RecorderSettings) {
        let sanitized = settings.validated()
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
