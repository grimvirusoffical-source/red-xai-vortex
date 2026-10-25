# Sign-in and Terms of Service

Every Red-XAI Vortex app (macOS, Windows, Linux) and the web pages require two things before use:

1. **Accept the Terms of Service** ([TERMS.md](TERMS.md)). Shown on first launch with **Accept** and
   **Decline and Quit**. The accepted version is stored locally; when the Terms change, you are asked again.
   On the web, signed-in pages redirect to `/vortex/terms/` until you accept.
2. **Sign in with a red-xai.com (RedX) account.** No account? Create one at https://red-xai.com.
   - Enter your username or email and password.
   - If two-factor is on, enter the 6-digit authenticator code, or choose **Call me instead**.
   - If your account needs two-factor setup, finish it on red-xai.com first.
   - The session token is stored in the OS keychain (macOS Keychain / Windows Credential Manager / Secret Service), never in plain files.
   - If RedX accounts are briefly unreachable, a previously signed-in app keeps working (offline grace).
   - Sign out: macOS app menu → **Sign Out of RedX**; desktop footer → **Sign out**.

Sign-in uses the public accounts API at `https://api.red-xai.com/v1/accounts/` over HTTPS.

**Owner mode** (the server owner connected over SSH with the admin key) skips the RedX sign-in but still requires the Terms.
