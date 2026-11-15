# No Ads Remote

Ad-free TV remote for iPhone. It stays on your Wi-Fi: no accounts, no analytics, no ads. Portrait controls, a full-width direction pad, and a row of streaming apps you can reorder. The app lists and controls LG webOS and Roku only.

Bundle id `com.zenithworkspaces.tvremote`. Display name **No Ads Remote**. Minimum iOS 17. iPhone, portrait, dark.

## What works

| TV | Status | How control works |
| --- | --- | --- |
| Roku | Ready | ECP on port 8060. `POST /keypress/…`, `POST /launch/{appId}`, `GET /query/apps`. Channel ids are taken from the TV's installed apps when the name matches, otherwise a known fallback. |
| LG webOS | Ready | SSAP over `wss://tv:3001` (self-signed cert accepted for that host only). Falls back to `ws://tv:3000`. The TV shows a PIN; the client key is stored in the Keychain. D-pad, OK, back, home, and media keys go out the pointer socket. Volume, mute, channel, input, power off, app launch, and the keyboard use `ssap://`. Power on is Wake-on-LAN after the MAC has been learned. |
| Samsung Tizen | Not offered | Websocket code remains in the project. The app does not list Samsung sets. |
| Sony Bravia | Not offered | IRCC code remains in the project. The app does not list Sony sets. |
| Vizio SmartCast | Not offered | Pairing code remains in the project. The app does not list Vizio sets. |
| Android / Google TV | Not offered | Discovery hits are ignored. Remote v2 pairing is not finished. |
| Fire TV | Not offered | Bonjour names such as `amzn.dmgr:…` are ignored. There is no supported local remote API. |

The screen, top to bottom: Power and the centered TV name, then Home / Input / Menu / Keyboard, app logos, then a square plus-shaped pad. Back sits in the pad's top-right corner. Volume, mute, and channel sit in the bottom corners. Skip previous, rewind, play/pause, fast forward, and skip next sit on the bottom row. Holding a direction repeats that key. Roku skip-previous is Instant Replay; Roku has no skip-next key, so that button is for LG. Light haptics. Keypresses are fire-and-forget on a kept-open session.

App row: Netflix, Prime Video, Disney+, YouTube, Hulu, Peacock, Paramount+, Apple TV+, Spotify. Long-press to reorder or hide. YouTube TV and Max stay available from that edit mode. The name you give a TV is saved on this phone.

The last TV you used is opened again next launch. Tap the name while connected to switch TVs, rename, or add another.

## Pairing

Put the phone on the same Wi-Fi as the TV.

- **Roku.** Nothing to pair. On the Roku, set *Settings → System → Advanced system settings → Control by mobile apps* to *Enabled* (or *Permissive*). *Limited* will refuse keypresses.
- **LG.** The TV shows a PIN. Type it in the app. Nothing else has to be pressed on the TV. The client key is saved, so it does not ask again. If that TV cannot do PIN pairing, the app asks you to accept the connection on the TV instead. The small joystick under the TV presses OK. Power-on needs the MAC address, which the app stores the first time a connection succeeds while the TV is on. If Wake-on-LAN doesn't turn the set on, enable *Mobile TV On* / LG Connect Apps on the TV.
- **Not found.** Same Wi-Fi, TV on, then Scan Wi-Fi or Add by IP. If a socket drops after a good connection, the app retries a few times and then tells you it couldn't reconnect. Samsung, Sony, Vizio, Android TV, and Fire TV are not listed.

## Discovery without the multicast entitlement

The app tries, in order:

1. Bonjour (`_googlecast._tcp`, `_androidtvremote2._tcp`, `_lgsmarttv._tcp`, `_samsungmsf._tcp`, `_amzn-wplay._tcp`, `_viziocast._tcp`, `_roku._tcp`).
2. Multicast SSDP to `239.255.255.250:1900` for `roku:ecp`, `urn:lge-com:service:webos-second-screen:1`, and DIAL.
3. Unicast SSDP to port 1900 across the phone's /24.
4. If that finds nothing (or you tap Scan), a TCP scan of the /24 on 8060, 3000, 3001, 8001, 8002, 7345, 9000, 6466, and 8008.

Multicast SSDP needs the `com.apple.developer.networking.multicast` entitlement. That capability is granted per App ID in the Apple Developer portal and **will fail signing if it is listed before Apple has approved it**, so the signed app does not include it. An example plist is in `Config/TVRemote.multicast.entitlements.example`. Add the capability to App ID `com.zenithworkspaces.tvremote` on team `938ZF88Q6G`, then point the target at that entitlements file. Until then, unicast SSDP and the port scan are what actually find TVs.

Local network access is declared with `NSLocalNetworkUsageDescription` and `NSBonjourServices`. Cleartext HTTP to the TV is allowed only for local networking (`NSAllowsLocalNetworking`). `ITSAppUsesNonExemptEncryption` is false. Saved TV names live in UserDefaults. Pairing secrets live in the Keychain. Nothing is uploaded.

## Build

The Xcode project is generated. Don't commit it.

```bash
brew install xcodegen
xcodegen generate
open TVRemote.xcodeproj
```

Debug is unsigned so CI can build a simulator without certificates. Release uses automatic signing, team `938ZF88Q6G`.

Unit tests cover key mapping and the Roku ECP / LG SSAP message builders (plus Samsung, Sony, Vizio, Wake-on-LAN, and SSDP framing).

## CI and TestFlight

The owner doesn't need a Mac. GitHub Actions on `macos-15` does the build.

- `.github/workflows/ci.yml` runs on pull requests and on pushes to `main`. It generates the project, builds, and tests on an iPhone simulator. Unsigned. 30 minute timeout. New runs cancel the previous one on the same ref.
- `.github/workflows/testflight.yml` runs on pushes to `main` and `workflow_dispatch`. It archives with `xcodebuild -allowProvisioningUpdates` and an App Store Connect API key, exports with method `app-store-connect` and destination `upload`, and sets the build number to `github.run_number`.

TestFlight secrets (repository Actions secrets, never committed):

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | API issuer id |
| `ASC_KEY_P8` | The `.p8` private key, raw PEM or base64 |
| `APPLE_TEAM_ID` | Apple team id (`938ZF88Q6G`) |

The workflow writes the `.p8` to a temp file with mode `600`, uses it, and deletes it. It does not print the key. If any of those secrets are missing, the TestFlight job skips and says which names are missing instead of failing the build.

The App Store Connect app for `com.zenithworkspaces.tvremote` already exists (Apple ID 6834946756). The workflow does not create it. It selects Xcode 26 or newer on the `macos-15` runner, because App Store Connect rejects binaries built with the iOS 18 SDK. Archive uses automatic signing and `-allowProvisioningUpdates` with the API key so Xcode can create the distribution certificate and profile. The first archive also registers one placeholder device named "No Ads Remote CI", because automatic signing cannot create a profile when the team has no devices. The API key needs Admin access so it can manage certificates, profiles, and devices, and upload builds.

## What you still need to do

1. Merge to `main` when you want the TestFlight workflow to run. A push to `main` archives and uploads. `workflow_dispatch` does the same.
2. Optional: request the multicast networking entitlement, then add `Config/TVRemote.multicast.entitlements.example` to the app target. Discovery already works without it.
3. On the TVs, turn on the control settings in the pairing section. Roku and LG are the ones that are meant to be solid.
