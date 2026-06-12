import Foundation
import Supabase

/// Vends the single configured Supabase client for the whole app.
/// The SDK persists the auth session to the keychain across launches.
enum SupabaseClientProvider {
    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey
    )
}
