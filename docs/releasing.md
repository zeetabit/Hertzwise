# Releasing Hertzwise

A release is a pushed tag. Everything else — build, signing, the update feed —
runs in the `Release` workflow (`.github/workflows/release.yml`), which calls
`scripts/release.sh`.

## Cutting a release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project and
   `CFBundleShortVersionString` / `CFBundleVersion` in `Info.plist`, merge to
   `main`. The build number must grow: Sparkle compares it to find newer
   versions.
2. Tag `main` with an **annotated** tag whose message is the release notes:
   `git tag -a vX.Y.Z main -F notes.txt`, then `git push origin vX.Y.Z`.
3. The workflow builds the tag from a clean checkout, signs it, publishes the
   release with `Hertzwise-X.Y.Z.dmg` and `appcast.xml`, and uses the tag
   message as the release notes (on GitHub and in Sparkle's update window).
4. Check: the release has both assets, and
   `https://github.com/zeetabit/Hertzwise/releases/latest/download/appcast.xml`
   serves the new version.

`scripts/release.sh [ref]` runs the same steps locally (identity and Sparkle
key from the keychain) and writes `build/release/`.

## The two keys

Both are self-made and free; neither needs an Apple Developer membership.

| Key | What it does | Where it lives |
|---|---|---|
| **"Hertzwise" code-signing identity** (self-signed certificate) | Signs the app. One stable identity keeps the app's designated requirement the same across releases, so macOS keeps the user's permissions after an update, and Sparkle accepts the update as the same app. | Login keychain (My Certificates → "Hertzwise"); secrets `HERTZWISE_SIGNING_P12` and `HERTZWISE_SIGNING_P12_PASSWORD`; the password also in the keychain item "Hertzwise signing key password". |
| **Sparkle EdDSA key** | Signs each update in the appcast; the app checks it against `SUPublicEDKey` in `Info.plist` before installing. | Login keychain (Sparkle's item, account `hertzwise`); secret `SPARKLE_ED_PRIVATE_KEY`. |

GitHub secrets can't be read back, so they are not a backup. Keep an export
of each key somewhere safe (a password manager):

- identity: Keychain Access → login → My Certificates → "Hertzwise" →
  Export → `.p12`;
- Sparkle key: `generate_keys --account hertzwise -x sparkle-key.txt` (the
  tool is in Sparkle's package artifacts, `SourcePackages/artifacts/sparkle/Sparkle/bin`).

### If a key is lost

- **Identity:** make a new one and update the two secrets. Users' next update
  still installs (Sparkle checks the EdDSA signature), but macOS sees a new
  app and asks for its permissions once more.
- **Sparkle key:** installed copies can no longer verify updates. Ship the new
  public key in a release users install by hand, then sign with the new key.

## Why the signing is set up this way

- **Not notarized.** Notarization needs a paid Developer ID. Users clear the
  quarantine flag once on the first download; updates installed by Sparkle
  carry no quarantine.
- **Library validation is off in release builds** (`release.sh` adds
  `com.apple.security.cs.disable-library-validation`). A self-signed identity
  has no Team ID, so the hardened runtime's library validation refuses even
  the app's own frameworks ("different Team IDs") and the app quits at launch.
  The hardened runtime stays on.
- **No `get-task-allow`.** Overriding signing on the command line made Xcode
  inject the debug entitlement; `release.sh` builds with
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` and refuses a build that carries it.
- **Sparkle's helpers are signed inside out** with the same identity (XPC
  services, `Autoupdate`, `Updater.app`, then the framework, then the app).
  Sparkle checks these match before it installs.
- **The feed is a release asset.** `releases/latest/download/appcast.xml`
  always resolves to the newest release's copy, so nothing else is hosted.

## Setting up a new Mac

1. Import the identity `.p12` into the login keychain (double-click it), and
   the Sparkle key with `generate_keys --account hertzwise -f sparkle-key.txt`.
2. Optional, for local builds signed like releases (one set of permissions
   for Xcode builds and the installed app): the project reads two variables,
   `HERTZWISE_CODE_SIGN_STYLE` and `HERTZWISE_ENTITLEMENTS`, which default to
   automatic signing and `SampleRateSwitcher.entitlements`. Set them in an
   untracked xcconfig used as the project's base configuration:

   ```
   DEVELOPMENT_TEAM =
   HERTZWISE_CODE_SIGN_STYLE = Manual
   CODE_SIGN_IDENTITY = Hertzwise
   HERTZWISE_ENTITLEMENTS = Signing.local.entitlements
   ```

   where `Signing.local.entitlements` is `SampleRateSwitcher.entitlements`
   plus `com.apple.security.cs.disable-library-validation` (see above).
