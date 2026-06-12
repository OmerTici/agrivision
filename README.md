## Setup (operator inputs required before building)

1. **Supabase anon key.** In the Supabase dashboard → Project Settings → API, copy the
   **anon / publishable** key (NOT the service-role key). Open
   `CarniVision/Info.plist` and replace `REPLACE_WITH_SUPABASE_ANON_KEY` in the
   `SUPABASE_ANON_KEY` value with the copied key. The service-role key must never ship
   in the app.
2. **SPM package.** supabase-swift is pinned to an exact version in the Xcode project.
   If your machine resolved a different 2.x version, note it here.
3. **Sign Up button.** Supabase project signups are currently open. If you want to hide
   in-app sign up, see `AuthService` / `SignUpForm`.
