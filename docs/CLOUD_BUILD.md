# Cloud build & installing on iPhone (no Mac needed)

Homify Studio is a native Swift app. Apple only allows native apps on an
iPhone if they are **signed**, and signing requires an Apple developer account.
There is no permanent, official way to install a native app without it.
This guide uses only an iPhone and a browser.

## 1. What you need

| Item | Why | Cost |
|---|---|---|
| Apple Developer Program membership (individual) | Signing certificates, TestFlight | **US$99 / year** (charged in local currency). Enrol at developer.apple.com/programs/enroll; it works from Safari or the "Apple Developer" iPhone app. |
| GitHub account + this repository | Source code + macOS cloud builds (GitHub Actions) | Free. macOS runners cost nothing on a **public** repo. On a **private** repo they use your monthly Actions minutes, and macOS minutes count 10× (the free plan includes 2,000 min/month, which is roughly 200 macOS minutes; one build takes about 10–15 minutes). |
| TestFlight app on the iPhone | Installs the builds | Free |

> ⚠️ This repository is currently **public**. If you want the code private, go
> to *Settings → General → Danger Zone → Change visibility* on GitHub. Expect
> the macOS minutes limit above to apply after you do.

Without the paid program you can't sign a build on Apple's servers. (A free
"Personal Team" only works from Xcode on a Mac, and those builds expire after
7 days.)

## 2. One-time Apple setup (on the iPhone, in Safari)

1. **Team ID**: developer.apple.com → Account → Membership details → *Team ID* (10 characters).
2. **Create the app record**: appstoreconnect.apple.com → Apps → **+** → New App
   - Platform iOS, name "Homify Studio" (the name must be unique on the App Store; add a suffix if it's taken. The app will never be published.)
   - Bundle ID: if `studio.homify.app` is not offered, choose any unique ID you own,
     e.g. `com.<yourname>.homifystudio`, and register it first at
     developer.apple.com → Certificates, IDs & Profiles → Identifiers → **+** → App IDs.
   - SKU: anything, e.g. `homify-001`.
3. **API key for the cloud builder**: App Store Connect → Users and Access →
   Integrations → App Store Connect API → **Team Keys** → **+**
   - Name `GitHub CI`, Access **Admin**. Admin is required so Xcode can create
     the cloud-managed distribution certificate for you.
   - Note the **Key ID** and the **Issuer ID** shown above the table.
   - **Download** the `.p8` file. Apple lets you download it only once. It is
     saved to Files → Downloads.

## 3. Add repository secrets (GitHub, in Safari)

Repository → Settings → Secrets and variables → Actions → **New repository secret**:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | your Team ID |
| `BUNDLE_ID` | the bundle ID you registered, e.g. `com.yourname.homifystudio` |
| `ASC_KEY_ID` | Key ID of the API key |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | the **full text** of the `.p8` file. To get it: Files → Downloads → long-press the file → Quick Look / open with a text viewer, then Select All → Copy, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines. |

Never paste these values into a chat, issue or commit. GitHub encrypts secrets,
and the workflow deletes the key file at the end of every run.

## 4. Build and upload to TestFlight

GitHub → Actions → **TestFlight** → *Run workflow*. This also works from the
GitHub iPhone app. The workflow:

1. generates the Xcode project with XcodeGen,
2. archives a Release build on a macOS runner and lets Xcode cloud-sign it with your API key,
3. uploads the build to App Store Connect.

Apple then processes the build (about 5–30 minutes).

## 5. Install on the iPhone

1. App Store Connect → your app → **TestFlight**. The first time, answer the
   export-compliance question if asked. The app declares that it uses no
   non-exempt encryption, so this usually doesn't appear.
2. Under **Internal Testing** create a group, add yourself (your Apple ID
   email), and add the build.
3. Open the invitation email on the iPhone, or open the TestFlight app. Install.

### Limits

- A TestFlight build **expires after 90 days**. Run the workflow again to get a new one.
- Internal testers need no App Review.
- **Ad Hoc** distribution (an .ipa installed directly) is also possible, but you
  must register the iPhone's UDID and re-sign whenever the profile changes.
  TestFlight is simpler for a single device.
- When the membership lapses, existing builds stop launching.

## 6. Automatic checks on every push

`.github/workflows/ci.yml` runs on every push:

- **Core engine tests** on Linux and macOS (`swift test` in `Packages/HomifyCore`)
- **iOS build + integration tests** on an iPhone simulator. These generate real
  videos, edit them, export H.264 MP4 and decode the result.
- **Unsigned Release build for real devices** (arm64), to catch device-only compile errors.

Results are on the Actions tab. If a run fails, the logs are attached as artifacts.

## 7. Performance profiling on the real device

You can't run Instruments without a Mac. Phase 5 therefore plans:

- on-device `os_signpost` intervals plus a built-in debug HUD (FPS, memory, thermal state),
- MetricKit reports, which are delivered daily to the app for TestFlight builds.

Until that work is done, the performance targets in the brief are **not yet measured** on an iPhone 14.
