# TestFlight distribution

OLIV's bundle ID is `com.chayapat.oliv.ios`, team `SRAQ34JPLS`.
The app, keyboard and widget use the same version/build number. Build 15
has passed Release archive and App Store Connect export, including cloud-managed
Apple Distribution signing. Export alone does not make the app downloadable.
The app record is [OLIV Dictation (6819158448)](https://appstoreconnect.apple.com/apps/6819158448/distribution).
The short name OLIV was already taken in App Store Connect; the icon name remains OLIV.

Build 16 was archived, exported and successfully uploaded with released Xcode 27
(`27A266a`) on 5 October 2026. Apple accepted the package for processing at
13:16 Bangkok time. This upload succeeded; external testing still requires
processing and Beta App Review.
Build 16 is assigned to the external **OLIV Beta** group and has been submitted
to Beta App Review; its verified status is **Waiting for Review**.
The public invitation link is [Join OLIV Dictation on TestFlight](https://testflight.apple.com/join/SSYXfbej).
It is enabled and open to anyone, but Apple explicitly prevents enrollment
until the group has an approved build. This is not yet a working download link.
Automatic tester notification is enabled for this build.
On 5 October 2026,
`devicectl` independently confirmed that the paired iPhone was running 0.1.0 (14).
The latest runtime source is commit `3cde1a994a0d8bb73e3bf3883d55c072170aaa6b`,
which includes the build 14 trackpad/Delete improvements. The only runtime-path
diff for this submission is the encryption declaration in `App/Info.plist`.
Version/build metadata and distribution scripts were also updated.
All 64 recorded source/configuration hashes remained unchanged through the
archive and export. The exported app, keyboard and widget were verified as
0.1.0 (16), built with `27A266a`. Local evidence, source hashes and IPA SHA-256
are in ignored `build/TestFlight/source-manifest-16.json`.

The existing app icon is reused: `AppIcon.png`, 1024×1024, no alpha channel.
Beta description, review instructions and developer contact information are
saved in App Store Connect. The review API key is stored only in its private
review credentials, not in this document, source or app bundle.
The dedicated reviewer key passed a live authenticated request with 3.307 seconds
of synthetic English speech: dictation and cleanup succeeded in 1.048 seconds,
with no cleanup fallback. No microphone recording or user transcript was sent.

## Archive and upload

Sign into the developer account in Xcode → Settings → Apple Accounts.
Use the existing OLIV Dictation iOS app record in App Store Connect.
Automatic signing must have
access to the app and keyboard App Group `group.com.chayapat.oliv.ios`.

Use an Xcode/SDK supported by App Store Connect with the iOS platform installed.
The installed Xcode 26.6 currently reports a missing iOS 26.5 component and its
GUI cannot launch on this Mac. Xcode 27 beta 6 archives and exports successfully,
but Apple rejected its upload with **Unsupported SDK or Xcode version** on
5 October 2026. Build 15 is therefore **not available in TestFlight**.
Use the released [Xcode 27 (27A266a)](https://developer.apple.com/download/applications/)
or a newer Apple-supported release/RC. Install it side by side as
`/Applications/Xcode-27.app` to preserve the existing installations.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer Scripts/testflight.sh archive 16
DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer Scripts/testflight.sh export 16
DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer Scripts/testflight.sh upload 16
```

Archives and exports remain in ignored `build/TestFlight/`. The script will not
replace an existing archive. Choose a higher unused build number for a new
submission. `upload` sends the signed build to Apple using Xcode's signed-in
account. Export settings use App Store Connect distribution and permit external
TestFlight testing; do not choose **TestFlight Internal Only** in Organizer.

`ITSAppUsesNonExemptEncryption` is false because the app uses Apple's HTTPS,
Keychain and CryptoKit services, with no bundled encryption implementation.
Reassess this when adding cryptographic dependencies. See
[Apple's encryption guidance](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations).

## External testing and a shareable link

After Apple processes the uploaded build:

1. Open OLIV → TestFlight and fill Test Information: beta description,
   feedback email, review contact and review instructions.
2. Use the existing **OLIV Internal** and **OLIV Beta** external groups.
3. Add the build to the external group and submit for Beta App Review.
   Reviewers need a working, individually provisioned OLIV API key to test
   dictation; supply it securely through App Store Connect review information.
   Do not commit it or include it in the public beta description.
4. Once the build is approved, verify that the existing public link offers
   the approved build, then share it with testers.

Apple's [external tester instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
describe review and public-link availability. Builds expire after 90 days.

## Beta description (public)

OLIV turns Thai and English speech into editable text using your configured
OLIV server. Record in the app, keep a local transcript history, clean existing
text, and optionally use the OLIV keyboard and Shortcuts for dictation handoff.
Requires iOS 18 or later and an individual API key from your OLIV administrator.
The keyboard's Full Access is optional for ordinary typing and required for
dictation handoff. Recording begins only when you request it.

## What to test (public)

Set your individual API key in Settings. Test a foreground recording in Thai
and English, compare raw and cleaned text, and try copy/paste. If your key has
the clean scope, test Clean existing text. Optionally enable the OLIV keyboard
with Full Access and test English/Thai typing, cursor movement and deletion.
Action button automatic finish and repeated background activation remain
experimental; report failures and device/iOS version through TestFlight.

Each tester needs their own OLIV API key separately from TestFlight enrollment.
TestFlight installation does not grant access to the OLIV server.
