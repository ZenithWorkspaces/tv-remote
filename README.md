# No Ads Remote

Ad-free TV remote for iPhone. It stays on your Wi-Fi: no accounts, no analytics, no ads. Portrait controls, a full-width direction pad, and a row of streaming apps you can reorder. It controls LG webOS, Roku, Samsung Tizen, Google TV / Android TV, Vizio SmartCast, and Fire TV. Sony sets are not listed.

Bundle id `com.zenithworkspaces.tvremote`. Display name **No Ads Remote**. Minimum iOS 17. iPhone, portrait, dark.

## What works

| TV | Status | How control works |
| --- | --- | --- |
| Roku | Ready | ECP on port 8060. `POST /keypress/…`, `POST /launch/{appId}`, `GET /query/apps`. Channel ids are taken from the TV's installed apps when the name matches, otherwise a known fallback. |
| LG webOS | Ready | SSAP over `wss://tv:3001` first, then `ws://tv:3000`. The TV's self-signed certificate is accepted for that local host. Registration tries the classic signed manifest, then the same manifest without the signature block that current webOS rejects. The TV shows a PIN or an Allow prompt. A saved client key the TV rejects is deleted so pairing can start over. D-pad, OK, back, home, and media keys go out the pointer socket. Volume, mute, channel, input, power off, app launch, and the keyboard use `ssap://`. Power on is Wake-on-LAN after the MAC has been learned. |
| Samsung | Ready | 2016 and newer: `wss://tv:8002`, falling back to `ws://tv:8001`, with an allow prompt. 2014–2015 H/J sets: PIN pairing on port 8080, then an encrypted socket on port 8000. 2010–2013: the Allow prompt on port 55000. The session is stored in the Keychain. Older sets can't launch apps from the remote. Power on is Wake-on-LAN after the MAC is learned. |
| Vizio SmartCast | Ready | HTTPS on port 7345, or HTTP on 9000 for older sets. The TV shows a PIN. The auth token is stored in the Keychain. Keys use `/key_command/`. Known apps launch with `/app/launch`; Spotify has no stable id. Skip buttons are not on these sets. |
| Android / Google TV | Ready | Remote Service v2. Pairing is TLS on port 6467 with a 6-character code. Commands are TLS on port 6466. The phone keeps a certificate in the Keychain. Apps open by link. Power on is Wake-on-LAN, or Wake if the remote session is still up. |
| Fire TV | Ready, with setup | No local key API works while ADB debugging is off. The app speaks ADB on port 5555. The first connection asks you to allow the phone. App shortcuts start the Fire TV package. |
| Sony Bravia | Not offered | IRCC code remains in the project. The app does not list Sony sets. |

The screen, top to bottom: Power and the centered TV name, then Home / Input / Menu / Keyboard, app logos, then a square plus-shaped pad. Back sits in the pad's top-right corner. Volume, mute, and channel sit in the bottom corners. Skip previous, rewind, play/pause, fast forward, and skip next sit on the bottom row. Holding a direction repeats that key. Roku skip-previous is Instant Replay; Roku has no skip-next key, so that button is for LG. Light haptics. Keypresses are fire-and-forget on a kept-open session.

App row: Netflix, Prime Video, Disney+, YouTube, Hulu, Peacock, Paramount+, Apple TV+, Spotify. Long-press to reorder or hide. YouTube TV and Max stay available from that edit mode. The name you give a TV is saved on this phone.

The last TV you used is opened again next launch. Tap the name while connected to switch TVs, rename, or add another.

## Pairing

Put the phone on the same Wi-Fi as the TV.

- **Roku.** Nothing to pair. On the Roku, set *Settings → System → Advanced system settings → Control by mobile apps* to *Enabled* (or *Permissive*). *Limited* will refuse keypresses.
- **LG.** The TV shows a PIN. Type it in the app. Nothing else has to be pressed on the TV. The client key is saved, so it does not ask again. If that TV cannot do PIN pairing, the app asks you to accept the connection on the TV instead. The small joystick under the TV presses OK. A software update can reject the old pairing certificate or the saved key. The app registers again without that certificate, deletes a key the TV refuses, and shows the PIN or Allow screen. If neither appears, remove the TV in the app and add it again. Power-on needs the MAC address, which the app stores the first time a connection succeeds while the TV is on. If Wake-on-LAN doesn't turn the set on, enable *Mobile TV On* / LG Connect Apps on the TV.
- **Samsung.** 2016 and newer: allow the phone on the TV. 2014–2015: type the 4-digit PIN the TV shows. Older sets: choose Allow on the TV. Power-on needs the MAC, which the app stores after a connection while the TV is on.
- **Google TV / Android TV.** The TV shows a 6-character code. Type it in. The certificate stays on this phone.
- **Vizio.** Type the PIN from the TV. Some models reject an app shortcut; the status line says to open that app from the home screen.
- **Fire TV.** Turn on ADB debugging once: Settings → My Fire TV → About, select the name seven times if Developer options is missing, then Developer options → ADB debugging. Allow this phone when the TV asks.
- **Not found.** Same Wi-Fi, TV on, then Add TV and scan again. IP entry is under the menu's Advanced item. If a socket drops after a good connection, the app retries a few times and then tells you it couldn't reconnect. Sony sets are not listed.

## Discovery without the multicast entitlement

The app tries, in order:

1. Bonjour (`_googlecast._tcp`, `_androidtvremote2._tcp`, `_lgsmarttv._tcp`, `_samsungmsf._tcp`, `_amzn-wplay._tcp`, `_viziocast._tcp`, `_roku._tcp`).
2. Multicast SSDP to `239.255.255.250:1900` for `roku:ecp`, `urn:lge-com:service:webos-second-screen:1`, and DIAL.
3. Unicast SSDP to port 1900 across the phone's /24.
4. If that finds nothing (or you tap Scan), a TCP scan of the /24 on 8060, 3000, 3001, 8001, 8002, 7345, 9000, 6466, and 8008.

Multicast SSDP needs the `com.apple.developer.networking.multicast` entitlement. That capability is granted per App ID in the Apple Developer portal and **will fail signing if it is listed before Apple has approved it**, so the signed app does not include it. An example plist is in `Config/TVRemote.multicast.entitlements.example`. Add the capability to App ID `com.zenithworkspaces.tvremote` on team `938ZF88Q6G`, then point the target at that entitlements file. Until then, unicast SSDP and the port scan are what actually find TVs.

Local network access is declared with `NSLocalNetworkUsageDescription` and `NSBonjourServices`. `NSAllowsLocalNetworking` allows the local socket, including `wss://` to the TV. The URLSession delegate accepts that TV's self-signed certificate and does not accept certificates for other hosts. `ITSAppUsesNonExemptEncryption` is false. Saved TV names live in UserDefaults. Pairing secrets live in the Keychain. Nothing is uploaded.

## Build

The Xcode project is generated. Don't commit it.

```bash
brew install xcodegen
xcodegen generate
open TVRemote.xcodeproj
```

Debug is unsigned so CI can build a simulator without certificates. The generated Release configuration names team `938ZF88Q6G`. TestFlight overrides the archive to manual signing and does not ask Xcode to create certificates.

Unit tests cover key mapping and the Roku ECP / LG SSAP message builders, plus Samsung, Sony, Vizio, Android TV Remote v2, Fire TV ADB framing, Wake-on-LAN, and SSDP framing.

## CI and TestFlight

The owner doesn't need a Mac. GitHub Actions on `macos-15` does the build.

- `.github/workflows/ci.yml` runs on pull requests and on pushes to `main`. It generates the project, builds, and tests on an iPhone simulator. Unsigned. 30 minute timeout. New runs cancel the previous one on the same ref.
- `.github/workflows/testflight.yml` runs on pushes to `main` and `workflow_dispatch`. It imports one stored Apple Distribution certificate into a temporary keychain, installs the App Store profile `No Ads Remote App Store CI`, archives with manual signing, and exports with method `app-store-connect`, `signingStyle` manual, and destination `upload`. The build number is `github.run_number`, except workflow run 12 publishes build 11 and run 13 publishes build 12.

TestFlight secrets (repository Actions secrets, never committed):

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | API issuer id |
| `ASC_KEY_P8` | The `.p8` private key, raw PEM or base64. Used only to upload the build. |
| `APPLE_TEAM_ID` | Apple team id (`938ZF88Q6G`) |
| `IOS_DIST_CERT_P12_BASE64` | Base64 of the Apple Distribution `.p12` (PBE-SHA1-3DES / MAC SHA-1) |
| `IOS_DIST_CERT_PASSWORD` | Password for that `.p12` |
| `IOS_APPSTORE_PROFILE_BASE64` | Base64 of the App Store profile `No Ads Remote App Store CI` |

The workflow writes the `.p8`, `.p12`, and profile to temp files with mode `600`, uses them, and deletes them. An `always()` step deletes the temporary keychain. It does not print secret values. If any of those secrets are missing, the TestFlight job skips and says which names are missing instead of failing the build.

The App Store Connect app for `com.zenithworkspaces.tvremote` already exists (Apple ID 6834946756). The workflow does not create it, and it does not create or revoke certificates or devices. It selects Xcode 26 or newer on the `macos-15` runner, because App Store Connect rejects binaries built with the iOS 18 SDK. The archive uses `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY=Apple Distribution`, team `938ZF88Q6G`, and profile `No Ads Remote App Store CI` (`20c9db5e-011f-4fbd-8d77-3da5fb836214`). The temporary keychain is the only one on the codesign search list, so the older Apple Distribution certificate with the same display name cannot be selected. The API key is installed only so `xcodebuild -exportArchive` can upload.

## What you still need to do

1. Merge to `main` when you want the TestFlight workflow to run. A push to `main` archives and uploads. `workflow_dispatch` does the same.
2. Optional: request the multicast networking entitlement, then add `Config/TVRemote.multicast.entitlements.example` to the app target. Discovery already works without it.
3. On the TVs, turn on the control settings in the pairing section. Fire TV needs ADB debugging before the buttons work.
