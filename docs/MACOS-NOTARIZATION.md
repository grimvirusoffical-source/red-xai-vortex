# macOS signing and notarization

A valid Developer ID signature and Apple notarization are separate requirements. A signature alone can still produce the “Apple cannot check it for malicious software” warning. Publish the final accepted, stapled artifact; do not ask users to disable Gatekeeper or remove quarantine as a fix.

## Prepare an isolated release copy

Copy the intended installed or built `.app` into a private staging directory with `ditto`. Keep its complete Resources directory, both RSX runtimes, frontend, and helpers. This does not copy or replace the user’s chats/settings, which live outside the app bundle. Do not modify `/Applications` while preparing a candidate.

Use `app/build.sh` for new builds. Every bundled Mach-O executable, including both Python executables, must have a valid Developer ID signature, secure timestamp, and hardened runtime. Verify nested executables before signing the outer app. Retain the main app’s audio-input and Apple-events entitlements. The existing `llama-server` additionally needs only `com.apple.security.cs.disable-library-validation=true` to retain its external Homebrew OpenSSL loading; the build script applies that exception to this helper, with hardened runtime enabled. Test `llama-server --help` before and after signing.

```sh
codesign --verify --deep --strict "$STAGED_APP"
codesign -dv --verbose=4 "$STAGED_APP"
codesign -dv --verbose=4 "$STAGED_APP/Contents/Resources/llama-server"
```

Confirm the expected Developer ID team, `runtime` flag, timestamp, architectures, version, and entitlements. Do not re-sign or change bundle contents after acceptance without repeating notarization.

## Authenticate without putting credentials in Git

Keep private `.p8` files outside the repository with restrictive permissions. Never put their contents, an app-specific password, or generated authentication tokens in scripts, exports, logs, or commits. `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, and `NOTARY_PROFILE` below are locally supplied variables; no credentials are supplied by this repository.

For a team App Store Connect API key, save a profile once:

```sh
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID"
```

Alternatively, use the secure interactive password prompt. Supply the Apple ID and team, but omit the password option:

```sh
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
```

Default profiles use the data-protection keychain (iCloud or Local Items). Do not assume that inspecting only `login.keychain-db` establishes whether a profile exists.

## Submit through Xcode or notarytool

**Existing Xcode account:** with a valid app archive and the developer account configured in Xcode, use Organizer → Distribute App → Developer ID → Upload. An automated archive export can use `xcodebuild -exportArchive` with export options `method=developer-id`, `destination=upload`, the expected team, and the intended signing certificate/style. This route can use Xcode’s existing account credentials. `-exportNotarizedApp` exports an archive that is already notarized; it does not submit one.

Xcode may re-sign the product during upload. Its submitted product can be under `Vortex.xcarchive/Submissions/<submission-id>/`. **Use that exact final submitted app**, rather than the original input app, for stapling, validation, and packaging. Compare its entitlements, runtime flags, architectures, version, helper startup, and Developer ID team against the reviewed candidate.

**Command line:** ZIP the already signed candidate and submit once:

```sh
ditto -c -k --keepParent "$STAGED_APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
```

Record the returned submission ID. Require `Accepted`; if pending, query/wait for that existing ID rather than uploading duplicates. For failures, retrieve its log and fix the actual reported issue:

```sh
xcrun notarytool info "$NOTARY_JOB_ID" --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool log "$NOTARY_JOB_ID" --keychain-profile "$NOTARY_PROFILE" "$NOTARY_LOG"
```

## Staple, package, and verify the delivered files

After acceptance, set `FINAL_APP` to the actual submitted product:

```sh
xcrun stapler staple "$FINAL_APP"
xcrun stapler validate "$FINAL_APP"
codesign --verify --deep --strict "$FINAL_APP"
spctl --assess --type execute --verbose=4 "$FINAL_APP"
ditto -c -k --keepParent "$FINAL_APP" "$RELEASE_ZIP"
```

The assessment must accept the app as `Notarized Developer ID`. A ZIP cannot itself be stapled; rebuild the downloadable ZIP from the stapled app. Extract and validate a fresh copy of that final ZIP to verify ticket preservation.

A downloadable DMG is a separate distribution artifact. Create it with the final stapled app inside, sign the DMG with Developer ID and a timestamp, submit the DMG for notarization, require acceptance, and staple/validate the DMG separately. Validate its signature and Gatekeeper assessment as well as the app inside. Do not reuse a ticket from a differently signed or modified image.

## Repairing the 2.10 downloads

A signature/notarization packaging repair can retain app version **2.10 / build 45** when application behavior has not changed. Replace both Mac ZIP and DMG with the validated final artifacts, regenerate their hashes in the release manifest and checksums, re-sign the manifest with the authorized release key, and update every download mirror/cache. Keep the release/tag, signed manifest version, and app bundle version consistent; the updater checks them.

An already installed 2.10 app will not discover a same-version repair as an upgrade. Provide a fresh download for this repair. A future automatic upgrade requires a coordinated version/build, release tag, and manifest bump followed by signing and notarization of that new version.

## Apple references

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Saved notarization credentials and data-protection keychains](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
