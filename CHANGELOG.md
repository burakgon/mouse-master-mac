# Changelog

## Unreleased

- Installing an update no longer pauses the mouse while Mouse Master checks the download's
  signature.

## 1.1.0

- Updates from GitHub. Mouse Master looks for a new version a few times a day (Settings ›
  Updates turns this off) and offers to install it: from a notification, the menu bar, Settings › Updates or `mmctl update`. It installs
  only an app signed by the same developer, then restarts by itself and reopens its window.
- Signed with Developer ID and notarized: the download opens without warnings, and macOS keeps
  the Accessibility and Input Monitoring permissions across updates.
- Updating no longer leaves a "Mouse Master quit unexpectedly" report behind. launchd killed the
  first start of every new build because it did not recognise the signature.
- Smooth zoom starts at once in Chromium browsers (Chrome, Brave, Edge, Vivaldi, Opera, Arc).
  They ignore the start of every pinch, up to half the page size; the pinch now opens with one
  step they swallow, so zooming no longer waits for a third of a turn of the thumb wheel.
- Scrolling right after zooming no longer stalls. The pinch ends the moment the thumb wheel
  stops or anything scrolls, instead of a quarter second later (Chromium ignored scrolling that
  began during the pinch until the wheel rested).

## 1.0.0

The first release.

- Remap every button of Logitech HID++ mice to built-in actions, keyboard shortcuts, apps, files,
  websites, Shortcuts, shell commands, typed text and macros.
- Gestures on every button that reports motion, with pan and zoom modes and presets.
- Smooth, high-resolution scrolling with speed, acceleration and a scroll direction of its own.
- Smooth pinch zoom, sideways scrolling and custom actions on the thumb wheel; tap actions.
- Pointer speed, precision mode, SmartShift, ratchet and free spin, ratchet force.
- Per-app setups that follow the frontmost app.
- Easy-Switch: see, rename and switch computers.
- Battery in the menu bar, low battery notifications and an on-screen display.
- Bluetooth and Logi Bolt, Unifying and Lightspeed receivers.
- `mmctl`, a command line client.
