# ClipSave

ClipSave saves permitted public MP4 videos and shares them through the Android share sheet. Direct HTTPS MP4 links download on the phone without a PC, an account, or a backend. YouTube Shorts still use the optional ClipSave backend.

## Install on Android

1. Download `ClipSave-android-arm64.apk` from [GitHub Releases](https://github.com/Re-Haiyan/ClipSave/releases) on a 64-bit ARM Android phone. Open the APK to install. Android may ask you to allow installs from the app you opened it with.
2. Paste a public HTTPS URL that returns an MP4 file directly. Tap **Preview link**, then **Download MP4**. Direct downloads use the original quality and have a 100 MiB transfer cap.
3. Check **Saved videos** and use the system share sheet to send the MP4 to an installed app.

For YouTube Shorts, start a [ClipSave backend](ClipSave/README.md#windows-backend) and enter its address in **Settings**. Use videos you own or have permission to download.

Test APKs are debug-signed to support an optional local HTTP backend. If Android reports a signing conflict when upgrading, share or export any saved videos you want to keep before uninstalling the earlier build.

See the [project guide](ClipSave/README.md) for development, backend tests, and iOS setup.
