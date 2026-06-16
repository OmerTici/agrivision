# Samper Labs — Auth Email Templates

Branded HTML email templates for the Supabase Auth flows, styled to the
samperlabs.com identity (deep navy `#0E2A47`, green→blue gradient
`#2BC07C → #1C9FD6 → #1C84E0`, white/`#F4F7FA` surfaces, Lato type, real logo).

Open **`_preview.html`** in a browser to see all eight at once.

## Files → Supabase slots

Dashboard → **Authentication → Emails → Templates**. Paste each file's full HTML
into the matching template, then **Save**.

| File | Supabase template | Key variables used |
|------|-------------------|--------------------|
| `confirm-signup.html`    | **Confirm sign up**        | `{{ .ConfirmationURL }}` |
| `magic-link.html`        | **Magic Link / OTP**       | `{{ .ConfirmationURL }}`, `{{ .Token }}` |
| `reset-password.html`    | **Reset Password**         | `{{ .ConfirmationURL }}` |
| `invite.html`            | **Invite user**            | `{{ .ConfirmationURL }}` |
| `change-email.html`      | **Change Email Address**   | `{{ .ConfirmationURL }}`, `{{ .Email }}`, `{{ .NewEmail }}` |
| `reauthentication.html`  | **Reauthentication**       | `{{ .Token }}` (6-digit code, no URL) |
| `password-changed.html`  | Security notifications → **Password changed** | `{{ .Email }}` (no URL — informational) |
| `email-changed.html`     | Security notifications → **Email address changed** | `{{ .Email }}` (previous), `{{ .NewEmail }}` (no URL — informational) |

> The last two are the **security notifications** toggled under
> Authentication → Emails → *Security notifications* (Password changed / Email
> address changed). They are informational — no action link. The email-change
> notice is delivered to the **previous** address so the user can react if the
> change wasn't authorized.

> Set each template's **Subject** in the dashboard, e.g.
> Confirm sign up → `Confirm your email` · Magic Link → `Your Samper Labs sign-in link` ·
> Reset Password → `Reset your password` · Invite → `You're invited to Samper Labs` ·
> Change Email → `Verify your new email` · Reauthentication → `Your verification code`.

## ⚠️ Step 1 — publish the logo (required before sending)

Email clients can only load images over `https://`. The logo
`samperlabs-email-logo.png` has been added to the website's
`samperlabs/public/` and `samperlabs/build/` folders, but it isn't live until
you deploy:

```bash
# from /Users/korkutkaanbalta/Documents/Samper-labs-website
./deploy-samperlabs.sh        # or: firebase deploy --only hosting:samperlabs
```

Confirm it's live:
```bash
curl -sI https://samperlabs.com/samperlabs-email-logo.png | head -1   # expect: HTTP/2 200
```
Until then, recipients see the alt text "Samper Labs". (The local `_preview.html`
falls back to the bundled copy automatically, so the preview always shows the logo.)

## Customising

- **Brand strings** — search/replace `Samper Labs`, `samperlabs.com`, and the
  footer tagline `the operating system for meat production` if the product name
  in-app differs (e.g. AgriVision). One pass per file.
- **Colors** — primary action/links `#1C84E0` (hover `#1668B8`); gradient stops
  `#2BC07C` / `#1C9FD6` / `#1C84E0`; headings `#0E2A47`; page bg `#F4F7FA`.
- **Logo size** — the `<img width="170">` in each header; height auto-scales.
- **Expiry copy** — the security note says 24 h (signup/invite) or 60 min
  (magic link/reset/reauth). Match these to **Auth → Sessions / Rate limits**.

## Client compatibility

Table-based layout, inline styles, bulletproof gradient buttons with a solid
`bgcolor` fallback for Outlook, `@media` mobile padding, and Lato via Google
Fonts with an `-apple-system / Segoe UI / Arial` fallback stack. Tested shape
for Apple Mail, Gmail (web/iOS/Android), and Outlook. The logo `<img>` carries an
`onerror` local fallback that email clients ignore (JS is stripped) — it only
helps the offline browser preview.

---

# Adding Google Sign-In (Supabase)

Yes — Supabase supports Google as an OAuth provider. Two parts: configure Google
Cloud, then wire the iOS app.

## 1. Google Cloud — OAuth client

1. <https://console.cloud.google.com> → APIs & Services → **OAuth consent screen**
   → External → fill app name (**Samper Labs**), support email, logo, domain
   `samperlabs.com`.
2. **Credentials → Create credentials → OAuth client ID**:
   - **Web application** client — this is the one Supabase uses.
     - Authorized redirect URI:
       `https://xznmsmweefckkqjfepqs.supabase.co/auth/v1/callback`
   - (Optional, for native Google SDK) an **iOS** client ID with your bundle id.
3. Copy the Web client's **Client ID** and **Client secret**.

## 2. Supabase — enable provider

Dashboard → **Authentication → Sign In / Providers → Google** → enable, paste the
Web **Client ID** + **Client secret** → Save. Confirm your app's callback scheme
`carnivision://auth-callback` is in **Authentication → URL Configuration →
Redirect URLs** (it's already used for the existing PKCE flow).

## 3. iOS — trigger the OAuth flow

The app already uses `supabase-swift` with PKCE and handles
`carnivision://auth-callback` (see `AgriVisionApp.swift` `onOpenURL` →
`AuthService.handleDeepLink`). Add a Google button that calls:

```swift
// AuthService.swift
func signInWithGoogle() async throws {
    try await SupabaseClientProvider.shared.auth.signInWithOAuth(
        provider: .google,
        redirectTo: URL(string: "carnivision://auth-callback")!
    )
    // supabase-swift opens the system browser / ASWebAuthenticationSession,
    // then your existing onOpenURL handler exchanges the code for a session.
}
```

For a native (no-browser) experience instead, add the **GoogleSignIn** SDK, get
an `idToken`, and call `auth.signInWithIdToken(credentials: .init(provider: .google, idToken: idToken))`.
The web-redirect flow above needs no extra SDK and reuses the deep-link plumbing
that's already in place.

> Note: these templates are for *email* auth. Google sign-in is OAuth and sends
> no email, so no template changes are needed — but enabling it gives users a
> one-tap alternative to the magic link / password flows.
