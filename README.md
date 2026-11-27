# ClipSave

ClipSave downloads permitted public MP4 and YouTube Shorts links. Preview a link, choose a quality when offered, and download the video. Saved videos stay on your device and can be shared through Android’s share sheet.

## Try it on Android

1. Open [GitHub Releases](https://github.com/Re-Haiyan/ClipSave/releases) and download `ClipSave-android-arm64.apk` from a completed test release. Open the APK on your phone to install it. Android may ask you to allow installs from the app you opened it with.
2. Start the Python backend on your PC using the [Windows instructions](ClipSave/README.md#windows-backend). You do not need the Flutter SDK to use the APK.
3. Connect the phone and PC to the same Wi-Fi. In ClipSave, tap **Connect to your backend** and enter `http://YOUR_PC_IP:8000`. Use the PC’s Wi-Fi IPv4 address from `ipconfig`.
4. Paste a direct MP4 link and tap **Preview link**. After downloading, check **Saved videos** and the system share sheet. For Shorts, the backend also needs Deno and a publicly available source.

Each APK is debug-signed for phone testing over local HTTP. If Android reports a signing conflict when upgrading, keep any saved videos you want before removing the old test installation.

See the [project guide](ClipSave/README.md) for development setup, tests, and iOS build instructions.
