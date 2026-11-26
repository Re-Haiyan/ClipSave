# ClipSave

ClipSave prepares public videos as MP4 files, saves them in the app’s local storage, and opens the system share sheet. Use direct MP4 links and public YouTube Shorts you own or have permission to download. Saved clips remain in **Saved videos** until you delete them or clear the app’s data.

## Windows backend

Open PowerShell in the extracted `ClipSave` folder. Install the prerequisites if needed, then reopen PowerShell so the executables are on `PATH`.

```powershell
winget install --id Python.Python.3.12 -e
winget install --id Gyan.FFmpeg -e
winget install --id DenoLand.Deno -e
```

Start the backend from the project root.

```powershell
Set-Location .\backend
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
ffmpeg -version
ffprobe -version
deno --version
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000 --limit-concurrency 32
```

Keep this PowerShell window open. Run `ipconfig` in a second window to find your PC’s Wi-Fi IPv4 address. Connect the phone and PC to the same Wi-Fi, then open `http://<PC-LAN-IP>:8000/health` on the phone. The page should return `{"status":"ok"}`. If Windows Firewall blocks the connection, use this command in **Administrator PowerShell** on a trusted network with the Windows profile set to Private.

```powershell
New-NetFirewallRule -DisplayName "ClipSave LAN 8000" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000 -Profile Private -RemoteAddress LocalSubnet
```

The backend is unauthenticated and intended for local development. Run one worker so requests see the same in-memory jobs. Keep port 8000 on your development LAN. Set up HTTPS and authentication before exposing it outside that LAN.

## Android phone

Install Flutter 3.50.1 and the Android tooling for Flutter. Use Android Studio’s SDK Manager to install Android SDK Platform 36, platform-tools, and the side-by-side NDK if Gradle requests it. Enable USB debugging on your phone, connect it by USB, and accept the debugging prompt.

Open a second PowerShell window in the extracted `ClipSave` folder.

```powershell
Set-Location .\mobile
flutter doctor -v
flutter doctor --android-licenses
flutter pub get
flutter devices
$ClipSaveApi = 'http://192.168.1.23:8000' # Replace 192.168.1.23 with your PC's LAN IPv4 address
$ClipSaveDevice = 'YOUR_ANDROID_DEVICE_ID' # Copy the ID from flutter devices
flutter run -d $ClipSaveDevice --debug --dart-define="CLIPSAVE_API_URL=$ClipSaveApi"
```

To produce an APK and install it over USB from the same window:

```powershell
flutter build apk --debug --dart-define="CLIPSAVE_API_URL=$ClipSaveApi"
adb -s $ClipSaveDevice install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

For an Android emulator, set `$ClipSaveApi = 'http://10.0.2.2:8000'` and use the emulator ID. You can also open the **Settings** icon in ClipSave and change the backend address without rebuilding. The saved address takes precedence over `CLIPSAVE_API_URL`. Only debug builds accept HTTP.

1. Paste a small direct MP4 URL you have permission to download. For example, use MDN’s CC0 flower sample at `https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4`.
2. Tap **Preview link**, confirm **Original**, then tap **Download MP4**.
3. After saving, check which apps appear in the system share sheet. CapCut and a Files destination depend on the apps and share targets installed on the device.
4. Open **Saved videos**, try sharing again, and delete the saved clip. Reopen ClipSave to check that the deletion persists.
5. Try canceling a larger authorized download, then try it again. For an authorized public Short, preview first and select 720p or 1080p if offered.

## iOS on macOS

Install Flutter 3.50.1 and Xcode. Run `flutter doctor -v` and complete the Xcode setup. To run on a physical iPhone, open `ios/Runner.xcworkspace` in Xcode and select your signing team under **Runner → Signing & Capabilities**. The iPhone must be on the same network as the backend for LAN testing. Allow local network access when prompted.

```bash
cd ClipSave/mobile
flutter pub get
flutter devices
CLIPSAVE_SERVER=http://192.168.1.23:8000 # Replace with your backend machine's LAN address
flutter run -d YOUR_IOS_DEVICE_ID --debug --dart-define=CLIPSAVE_API_URL="$CLIPSAVE_SERVER"
```

To build a signed release IPA after setting up signing, use an HTTPS backend.

```bash
flutter build ipa --dart-define=CLIPSAVE_API_URL=https://clipsave.example.com
```

## Tests

From the backend directory, with FFmpeg on `PATH`:

```powershell
.\.venv\Scripts\python.exe -m unittest -v
```

These tests generate a one-second synthetic MP4 and exercise the HTTP API with a controlled upstream transport. They check inspect, byte-for-byte retrieval, cancellation, retry, local FFmpeg merging, and rejection of private destinations. From the mobile directory run `flutter analyze` and `flutter test`.

## Backend API

| Request | Result |
| --- | --- |
| `GET /health` | Backend availability |
| `POST /inspect` with `{"url":"…"}` | Title, optional thumbnail, available MP4 choices |
| `POST /jobs` with `{"url":"…","quality":"original"}` | Job ID |
| `GET /jobs/{id}` | State, optional progress from 0 to 1, optional error |
| `DELETE /jobs/{id}` | Cancel preparation or discard a completed result |
| `GET /jobs/{id}/file` | Completed MP4 |

The backend caps downloads at 100 MiB and 10 minutes, uses a four-minute job timeout, handles up to two jobs and two previews concurrently, and expires job records and leftover results after 15 minutes. Direct sources must respond with MP4 bytes. YouTube needs yt-dlp’s current extractor and a supported JS runtime. Availability and formats can vary by source. FFmpeg merges separate media tracks and converts codecs when needed for MP4 playback.
