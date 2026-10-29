# Xcode Cloud delivery

## Status

Repository support is prepared. Apple-side onboarding, repository authorization,
the Firebase workflow secret, and a successful signed cloud archive/upload must
still be verified. Local verification is not evidence of TestFlight delivery.

The shared `EMSYS` scheme supports testing and Release archives. Keep the tracked
Swift package lock file. Cloud workflow settings live in Apple’s service; adding
scripts to Git does not enable a workflow by itself.

## Intended workflow

Create `EMSYS main TestFlight` for `embarques/emsys-swiftui`:

- Start condition: Branch Changes, only `main`, every change. Feature branches
  must not trigger distribution.
- Project: `EMSYS.xcodeproj`; scheme: `EMSYS`.
- Select a cloud Xcode version compatible with the project. It currently uses
  Xcode 27.1 locally and targets iOS 27.0; confirm cloud availability rather than
  changing the deployment target or signing to work around unavailable tooling.
- Add Test actions for iPhone, iPad, and macOS using eligible cloud destinations.
- Add an iOS Archive action, Release configuration, with TestFlight distribution.
- Add a TestFlight Internal Testing post-action for the owner’s chosen existing
  tester group. Create a group first if necessary; do not invite users implicitly.
- Use Apple-managed signing for the existing identity `com.embarqueros.emsys`
  and the intended developer team. Confirm the app record matches this identity.
- Check the next cloud build number against existing uploads before the first
  run. Use Xcode Cloud’s build numbering; do not commit a build-number increment
  on every push.

The first setup is through Xcode’s Integrate > Create Workflow flow with an Apple
Developer account and GitHub repository access. Refine settings in Xcode or
App Store Connect after onboarding. Keep any existing legacy workflow until the
new repository’s first successful upload is confirmed. A separate macOS archive
can be added when macOS distribution is requested.

This automates uploading builds to Apple/TestFlight. Public App Store release
still needs release preparation and App Review; it is not enabled by this setup.

## Firebase configuration

The legacy repository tracked its Firebase plist. This repository deliberately
ignores it. `ci_scripts/ci_post_clone.sh` restores the file before Xcode builds.

In the workflow Environment settings, add **secret** variable
`EMSYS_FIREBASE_CONFIG_BASE64` containing the single-line base64 encoding of the
approved local `EMSYS/Resources/GoogleService-Info.plist`. Enter it directly in
Apple’s secret field. Never paste its value into chat, PRs, Git, or build logs.
Base64 is transport encoding, not encryption; the secret setting protects it.

The script validates the plist, required Firebase keys, and bundle identity,
then atomically installs it with owner-only permissions. Missing or incorrect
configuration fails before building without logging values or modifying an
existing file. It does not change the local Firebase client, bundle identifier,
signing settings, or API configuration.

## Acceptance

1. Run `./scripts/verify.sh` locally; it includes synthetic cloud configuration
   success, retry, wrong identity, malformed input, and missing-secret checks.
2. Authorize the repository and add the secret in Apple’s workflow settings.
3. Manually run the workflow on the setup branch to validate before merging.
4. Confirm tests, signed archive, and upload succeed. Confirm the build appears
   under the correct App Store Connect app and is available to the intended
   internal TestFlight group.
5. After merging, confirm a change to `main` starts exactly the intended workflow
   and produces a new TestFlight build. Inspect Apple’s logs for configuration or
   signing problems; never paste credentials from logs into an issue.

## Apple references

- [First workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- [Custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [TestFlight distribution](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
- [Workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
