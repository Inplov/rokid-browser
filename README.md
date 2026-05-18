# AR Browser Remote for Rokid Glasses

Control a web browser on your Rokid AR glasses from your Android phone over Bluetooth.

> **Unofficial project** — not affiliated with Rokid. Built with ❤️ by the community.

[![Ko-fi](https://img.shields.io/badge/Support-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/inplov)

---

## What it does

- Browse the web on your Rokid glasses hands-free
- Control navigation, scrolling, zoom, and typing from your phone
- Manage glasses WiFi from the phone app
- Dark / light mode toggle for the glasses display
- Bookmark and history support

## Apps

| App | Runs on | Install |
|---|---|---|
| **AR Browser Remote** (phone) | Android phone | [Download APK](../../releases/latest) |
| **AR Browser** (glasses) | Rokid AR glasses | [Download APK](../../releases/latest) — see sideload instructions below |

---

## Glasses app — sideload via ADB

The glasses app cannot be distributed through the Play Store. You must install it manually.

**Requirements:**
- USB cable
- ADB installed on your PC ([download here](https://developer.android.com/tools/releases/platform-tools))
- Developer mode enabled on your Rokid glasses

**Steps:**

1. Download the latest glasses APK from [Releases](../../releases)
2. Connect your glasses to your PC via USB
3. Enable USB debugging on the glasses
4. Run:

```bash
adb install ar-browser-glasses.apk
```

5. Launch **AR Browser** on the glasses
6. Install the phone app and open it — it will connect automatically over Bluetooth

---

## Build from source

**Requirements:** Flutter 3.x, Android SDK

```bash
git clone https://github.com/yourusername/ar-browser-rokid.git
cd ar-browser-rokid

# Phone app
cd rokid_browser_phone
cp lib/secrets.dart.example lib/secrets.dart
# Edit lib/secrets.dart with your AdMob IDs (optional)
flutter pub get
flutter run

# Glasses app
cd ../rokid_browser_glasses
flutter pub get
flutter run
```

---

## Support the project

This app is free and open source. If it's useful to you, consider buying me a coffee — it helps keep the project maintained.

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/inplov)

---

## License

MIT
