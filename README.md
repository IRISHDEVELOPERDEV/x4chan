# X4chan — 4chan Monitor Android app (Flutter)

Companion app for the server-side monitor: a live Feed (All vs EE/Emily), an
Archive search over everything the server has saved, a Media gallery, Twitch
chat-log lookup, Stats, and Firebase push so EE/Emily alerts reach your phone
even when the app is closed.

There is nothing to configure in the app: the server address and API token are
built in. Settings only holds appearance, the feed filter, notifications, your
4chan Pass login and saved replies.

## Layout
- `app_src/` — the Flutter project (`lib/`, `pubspec.yaml`, `pubspec.lock`,
  committed `android/` project, tests).
- `.github/workflows/build.yml` — CI: analyze, test, build a signed release APK.
- `apk/X4chan.apk` — a ready-to-install build.

## How the build works
- **Server address**: `Config.baseUrl` in `app_src/lib/api.dart`
  (`https://x4chan.duckdns.org`, Caddy on the server proxying to the API).
- **API token**: never in the source. CI passes the `MONITOR_API_TOKEN` repo
  secret with `--dart-define=MONITOR_API_TOKEN=...`. If the server's token is
  rotated, update the secret and rebuild. An app with an old token shows
  "Token rejected — app needs rebuilding with the current token".
- **Signing**: release builds are signed with the X4chan release key, from the
  `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
  `ANDROID_KEY_PASSWORD` secrets. Without `android/key.properties` a local
  release build falls back to the debug key.
- **Version**: `versionName` comes from `pubspec.yaml`; the build number
  (`versionCode`) is the CI run number, so every build installs over the last.
- The APK is uploaded as a private workflow artifact (`X4chan-apk`, kept 7
  days). It is not published as a public release because it contains the token.

## Building locally
```bash
cd app_src
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=MONITOR_API_TOKEN=<token>
# -> build/app/outputs/flutter-apk/app-release.apk
```
Flutter version is pinned in the workflow (currently 3.47.7).

## Firebase / push
`app_src/android/app/google-services.json` is committed; the Google Services
Gradle plugin is applied in the committed Gradle files. The server sends the
pushes. Android 13+ asks for the notification permission on first launch.

## Endchan
While 4chan is read-only the server also follows the Endchan /b/ OTK general.
Its posts come back with `board: "endchan"`:
- The Feed, Media and Archive ask for `sort=time` (paging with `before_ts` +
  `before_no`), so Endchan posts sit among the 4chan ones by post time.
- Endchan cards are marked "Endchan"; Open, Reply and the archive button go to
  endchan.net (Reply opens Endchan in your browser), thumbnails come through
  the server's `/thumb` proxy.
- The thread button at the top of the Feed shows every post of the current
  Endchan OTK thread (`/thread?thread=<id>`), not just EE/Emily matches.

## Notes
- Feed images/videos load from 4chan's (or Endchan's) servers, so media from
  threads that have since been deleted won't display (the text and links remain).
- The in-app Reply browser only navigates within 4chan (4chan.org,
  4channel.org, 4cdn.org); other links open in your normal browser.
