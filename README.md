## Setup (operator inputs required before building)

1. **Supabase anon key.** The publishable key is committed in `AgriVision/Info.plist`
   (`SUPABASE_ANON_KEY`); rotate it from the Supabase dashboard if needed. The
   service-role key must never ship in the app.
2. **SPM package.** supabase-swift is pinned to 2.47.0 in the Xcode project.
3. **Sign Up button.** Supabase project signups are currently open. If you want to hide
   in-app sign up, see `AuthService` / `SignUpForm`.
