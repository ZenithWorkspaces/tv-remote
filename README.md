# No Ads Remote

Ad-free universal TV remote for iPhone. It stays on your Wi-Fi: no accounts, no analytics, no ads. Big portrait controls, a swipe pad, and a row of streaming apps. Roku and LG webOS are the ones to rely on. Samsung, Sony, and Vizio are beta. Android TV and Fire TV can be saved, but their buttons are off until those protocols are finished.

Bundle id `com.zenithworkspaces.tvremote`. Display name **No Ads Remote**. Minimum iOS 17. iPhone, portrait, dark.

## What works

| TV | Status | How control works |
| --- | --- | --- |
| Roku | Ready | ECP on port 8060. `POST /keypress/…`, `POST /launch/{appId}`, `GET /query/apps`. Channel ids are taken from the TV's installed apps when the name matches, otherwise a known fallback. |
| LG webOS | Ready | SSAP over `wss://tv:3001` (self-signed cert accepted for that host only). Falls back to `ws://tv:3000`. One-time Allow prompt on the TV. The client key is stored in the Keychain. D-pad, OK, back, home, and media keys go out the pointer socket. Volume, mute, channel, input, power off, app launch, and the keyboard use `ssap://`. Power on is Wake-on-LAN after the MAC has been learned. |
| Samsung Tizen | Beta | Websocket remote on `wss://tv:8002`, then `ws://tv:8001`. The TV shows an allow prompt; the token is kept in the Keychain. |
| Sony Bravia | Beta | IRCC `POST /sony/IRCC` with the TV's pre-shared key (`X-Auth-PSK`). |
| Vizio SmartCast | Beta | Pairing PIN on port 7345 (HTTPS) or 9000 (HTTP). The auth token is kept in the Keychain. |
| Android / Google TV | Saved only | Discovered (including `_androidtvremote2._tcp`). Remote v2 pairing (ports 6466/6467, protobuf) is not finished, so the pad stays disabled. |
| Fire TV | Saved only | Can be found from discovery. There is no supported local remote API in this build. |

Buttons: power, input, home, back, d-pad and OK, swipe pad, volume, mute, channel, play/pause, rewind, fast-forward, menu, and keyboard where the TV supports it (Roku literal `Lit_` keys, LG IME, Samsung text). Light haptics. Keypresses are fire-and-forget on a kept-open session.

App row: Netflix, Prime Video, Disney+, YouTube, YouTube TV, Max, Hulu, Peacock, Paramount+, Apple TV, Spotify.

The last TV you used is opened again next launch. Saved TVs stay in a switcher so an LG in one room and a Roku in another are one tap apart.

## Pairing

Put the phone on the same Wi-Fi as the TV.

- **Roku.** Nothing to pair. On the Roku, set *Settings → System → Advanced system settings → Control by mobile apps* to *Enabled* (or *Permissive*). *Limited* will refuse keypresses.
- **LG.** The first connection asks you to allow **No Ads Remote** on the TV screen. After that, the client key is reused. Power-on needs the MAC address, which the app stores the first time a connection succeeds while the TV is on. If Wake-on-LAN doesn't turn the set on, enable *Mobile TV On* / LG Connect Apps on the TV.
- **Samsung (beta).** Allow the device named No Ads Remote on the TV. Later launches reuse the token.
- **Sony (beta).** On the TV: *Settings → Network → Home network setup → IP control*. Turn on Simple IP control and set Authentication to *Normal and Pre-Shared Key*. Type that key into the app.
- **Vizio (beta).** The app starts pairing and the TV shows a PIN. Enter it in the app.
- **Not found.** Same Wi-Fi, TV on, then Scan Wi-Fi or Add by IP. If a socket drops after a good connection, the app retries a few times and then tells you it couldn't reconnect.

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

The App Store Connect app for `com.zenithworkspaces.tvremote` already exists (Apple ID 6834946756). The workflow does not create it. Archive uses automatic signing and `-allowProvisioningUpdates` with the API key so Xcode can create the distribution certificate and profile. The first archive also registers one placeholder device named "No Ads Remote CI", because automatic signing cannot create a profile when the team has no devices. The API key needs Admin access so it can manage certificates, profiles, and devices, and upload builds.

## What you still need to do

1. Merge to `main` when you want the TestFlight workflow to run. A push to `main` archives and uploads. `workflow_dispatch` does the same.
2. Optional: request the multicast networking entitlement, then add `Config/TVRemote.multicast.entitlements.example` to the app target. Discovery already works without it.
3. On the TVs, turn on the control settings in the pairing section. Roku and LG are the ones that are meant to be solid.
