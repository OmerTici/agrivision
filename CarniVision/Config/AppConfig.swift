import Foundation

/// Reads runtime configuration from Info.plist. The operator fills
/// `SUPABASE_ANON_KEY` before building (see README ▸ Setup).
enum AppConfig {
    private static func string(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            fatalError("Missing Info.plist key: \(key)")
        }
        return value
    }

    static var supabaseURL: URL {
        guard let url = URL(string: string("SUPABASE_URL")) else {
            fatalError("SUPABASE_URL is not a valid URL")
        }
        return url
    }

    static var supabaseAnonKey: String {
        let key = string("SUPABASE_ANON_KEY")
        if key == "REPLACE_WITH_SUPABASE_ANON_KEY" {
            fatalError("SUPABASE_ANON_KEY placeholder not replaced — see README ▸ Setup")
        }
        return key
    }

    static var embedderBaseURL: URL {
        guard let url = URL(string: string("EMBEDDER_URL")) else {
            fatalError("EMBEDDER_URL is not a valid URL")
        }
        return url
    }
}
