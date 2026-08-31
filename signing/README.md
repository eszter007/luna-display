# Signing

`make-apps.sh` signs both apps with the first "Developer ID Application"
identity in the login keychain, with the hardened runtime enabled. Without
one it falls back to ad-hoc signing, which is fine for personal use — the
only cost is Gatekeeper's right-click → Open step on the first launch on
another Mac, and macOS forgetting the Screen Recording grant when the
ad-hoc signature changes across rebuilds.

# Notarization

Notarized apps open on other Macs with no Gatekeeper friction at all.
`make-apps.sh` notarizes and staples both apps whenever a `notarytool`
keychain profile named `luna` exists (override the name with
`LUNA_NOTARY_PROFILE`, skip with `LUNA_NO_NOTARIZE=1`). Notarization needs
network access, an Apple Developer Program membership, and usually takes
one to a few minutes per submission.

One-time setup (the password never touches the repo — `notarytool` stores
it in the login keychain):

1. <https://account.apple.com> → *Sign-In and Security* → *App-Specific
   Passwords* → generate one (name it e.g. "luna notarytool").
2. Store it:

   ```sh
   xcrun notarytool store-credentials luna \
     --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID --password xxxx-xxxx-xxxx-xxxx
   ```

   (An App Store Connect API key works too: `--key`, `--key-id`, `--issuer`.)
3. `./make-apps.sh` — look for `notarized and stapled` in the output. If a
   submission is rejected the script prints the `notarytool log` command
   that explains why.
