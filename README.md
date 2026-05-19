# Rokid Remote

Control a web browser on your Rokid AR glasses from your Android phone over Bluetooth.

> **Unofficial project** — not affiliated with Rokid. Built with ❤️ by the community.

---

## Support the project ❤️

This app is **free**, built in my spare time, and kept alive by people who find it useful.
If it's brought you even a little joy — watching a video hands-free, browsing while cooking, or just the novelty of it — a small coffee goes a long way toward keeping it maintained and improving.

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/inplov)

No pressure at all — enjoying the app is enough. Thank you for being here. 🙏

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

## Apps

| App | Runs on | Install |
|---|---|---|
| **Rokid Remote** (phone) | Android phone | [Download APK](../../releases/latest) |
| **Rokid Browser** (glasses) | Rokid AR glasses | [Download APK](../../releases/latest) — see sideload instructions below |

---

## Glasses app — sideload via ADB

The glasses app must be installed manually via ADB.

**Requirements:**
- Rokid Debugging Cable (the original cable supports charging only)
- Developer mode enabled on your Rokid glasses

**Steps:**

1. Install ADB (Android Debug Bridge) on your PC:

```bash
# Windows (winget)
winget install --id Google.PlatformTools

# macOS (Homebrew)
brew install android-platform-tools

# Linux (apt)
sudo apt install adb
```

> **Windows:** Open a new terminal window after installing for `adb` to be recognised.

2. Download the latest glasses APK (`rokid-browser-glasses-*.apk`) from [Releases](../../releases)
3. Connect your glasses to your PC via USB using the Rokid Debugging Cable
4. Enable ADB debugging: open the **Hi Rokid** app → Settings → Developer
5. Run (replace the filename with the version you downloaded):

```bash
adb install rokid-browser-glasses-v1.0.0.apk
```

6. Launch **AR Browser** on the glasses
7. Install the phone app and open it — it will connect automatically over Bluetooth

---

## Build from source

**Requirements:** Flutter 3.x, Android SDK

```bash
git clone https://github.com/Inplov/rokid-browser.git
cd rokid-browser

# Phone app
cd rokid_browser_phone
cp lib/secrets.dart.example lib/secrets.dart
flutter pub get
flutter run

# Glasses app
cd ../rokid_browser_glasses
flutter pub get
flutter run
```

---

## License

MIT — free to use, modify, and share.

If this project has been useful to you, a coffee on [Ko-fi](https://ko-fi.com/inplov) is always appreciated. ☕
