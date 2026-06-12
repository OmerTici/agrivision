import Foundation
import Supabase

/// Vends the single configured Supabase client for the whole app.
/// The SDK persists the auth session to the keychain across launches.
enum SupabaseClientProvider {
    /// Deep link the email-confirmation / magic-link redirect lands on. Registered
    /// as a URL scheme in Info.plist (CFBundleURLSchemes) and must be allow-listed
    /// in the Supabase dashboard ▸ Authentication ▸ URL Configuration ▸ Redirect URLs.
    static let authRedirectURL = URL(string: "carnivision://auth-callback")!

    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                // Default redirect for signUp/magic-link so the email link returns
                // to the app instead of a web page.
                redirectToURL: authRedirectURL,
                // PKCE: the link carries a `code` we exchange in-app via
                // auth.session(from:). Default in supabase-swift; set explicitly.
                flowType: .pkce
            )
        )
    )
}
