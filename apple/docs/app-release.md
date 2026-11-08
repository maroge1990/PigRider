# Getting the app onto the iPad

Two ways, both signed with Mark's paid team (`6CUZWP49QT`) and driven from
this machine. Both ask for the **Mac login password** in the terminal: Xcode's
account lives in the login keychain, which an ssh session cannot open alone.
No API key or other secret is stored anywhere.

| | Command | Use |
| --- | --- | --- |
| TestFlight | `make -C apple testflight` | The normal way. Uploads HEAD's `apple/` (refuses uncommitted changes there), built from its own snapshot on the Mac so no other run can change it. The build appears in TestFlight after Apple's processing (10–30 min); the iPad updates from the TestFlight app. |
| Development build | `make -C apple ipad` | Quick checks with the iPad near the Mac (paired; Developer Mode on). Any tree. |

Both run `scripts/mac.sh`, which copies `apple/` to the Mac and runs
`scripts/signed.sh` there with `ssh -t`.

## Versions

- **Build number** (`CFBundleVersion`) = the Unix time of the upload, so it only
  grows, on any branch, and a retry gets a new one. The commit it came from is
  in the bundle (`PigRiderCommit`) and shown in the app's settings as
  `0.1.0 (build, commit)`; a development build of a changed tree says
  `<commit>-dirty`.
- **Marketing version** (`MARKETING_VERSION` in `project.yml`, 0.1.0) changes
  by hand when it means something.
- **Bridge version** (`apple/BRIDGE_VERSION`) is shown in the app's settings.
  Deploy rule (ADR 0002): a server release may not need a newer bridge than the
  installed app, so when it grows, TestFlight goes first, the server after.

## TestFlight setup (once)

- App Store Connect: app *PigRider*, bundle id `com.maroge1990.pigrider`
  (registered by Xcode's automatic signing), internal testing only
  (`ExportOptions.plist`: `testFlightInternalTestingOnly`). AGPL: no App
  Store release, no external testers (ADR 0001).
- Export compliance is answered in the bundle (`ITSAppUsesNonExemptEncryption`
  = false: standard TLS only).
- Mark is an internal tester; install the TestFlight app on the iPad.
- Xcode on the Mac must have Mark's Apple ID under Settings → Accounts.

The app icon is upstream's (lemon), a placeholder until Mark picks one.
