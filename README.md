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

---

## Phone app controls

| Control | Action |
|---|---|
| URL bar | Navigate to a URL or search Google |
| Back / Reload / Forward | Browser navigation |
| Trackpad | Move cursor on glasses — tap to click, hold to long-press, double-tap then drag to drag |
| Scroll arrows | Scroll the page up, down, left, right |
| Zoom In / Zoom Out | Adjust page zoom level |
| **Theater mode** | Pins the playing video fullscreen on the glasses display, hides everything else, and sets volume to max — ideal for YouTube and video sites |
| Exit Full | Exits fullscreen or theater mode |
| Keyboard | Type text into the focused input on the glasses |
| Block 3rd-party cookies | Blocks tracking cookies for the current session |
| Clear session | Clears cache, cookies, and local storage — logs you out of all sites |
| Exit Glasses App | Closes the browser on the glasses |

---

## Glasses hardware controls

These work directly on the Rokid glasses without touching your phone:

| Gesture | Action |
|---|---|
| **Swipe right** on touchpad | Toggle passthrough mode — dims the browser so you can see the real world through the waveguide |
| **Swipe left** on touchpad | Reload the current page |
| **Single tap** centre button | Play / pause media |
| **Double tap** centre button | Exit fullscreen or go back |
| **Volume up / down** buttons | Adjust media volume |
| **Back arrow** in HUD | Go back (tap on the `‹` icon) |
| **Bookmark icon** in HUD | Save current page to bookmarks |

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
