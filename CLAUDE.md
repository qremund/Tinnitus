# Tinnitus — notes for Claude

A personal iPhone app that measures the pitch, width, and loudness of the owner's tinnitus, then plays sleep sounds with that frequency band notched out. It is a personal tool, not a medical device. The owner is its only user and installs it from Xcode with a free Apple ID. See README.md for the layout and the research behind it.

## How the owner works

- The owner is not a professional developer. Explain things in plain language and skip jargon.
- Make changes on a new `claude/...` branch and open a pull request. The owner merges it on GitHub, then pulls with GitHub Desktop and runs the app from Xcode on a Mac.
- The README is written for the owner. When something changes, update it in the same pull request, in the same plain style.
- This repository is public. Don't commit personal data, such as a saved tinnitus profile or recordings.
- If you can't build the Xcode project in your environment (for example, a Linux cloud session), say so clearly in the pull request and list what the owner should check on the iPhone.

## Layout

- `TinnitusCore/`: a Swift package with all the audio math: tone and noise synthesis, biquad filters, notch design, pitch matching, sleep sound mixing, and profiles. No UI.
- `Tinnitus/`: the SwiftUI app (iOS 17 or later): matching flow, playback, profile, settings, and the audio engines that call into `TinnitusCore`.
- The app folder uses Xcode's synchronized folders, so new files in `Tinnitus/` are added to the build automatically.

## Tests

```sh
cd TinnitusCore
swift test
```

- Keep audio math and any other logic that doesn't need the UI in `TinnitusCore`, with unit tests. Keep the `Tinnitus/` app layer thin.
- `TinnitusCore` needs only Foundation, so its tests also run on Linux. Keep it that way: no AVFoundation or SwiftUI in the package.
- Run the tests before every pull request that touches `TinnitusCore`.

## Rules to keep

- Volume safety: test tones and sleep sounds fade in quietly and are capped by `SafetyLimits`. Keep the fades and caps when changing the audio code, and never raise the caps without the owner asking.
- Base changes to the measuring method on research, and cite it in the README's "Research behind it" section.
- Don't describe the app as treating or curing tinnitus.
- iOS 17 is the minimum. The project builds in Swift 5 language mode.

## Free Apple ID limits

- Apps installed with a free Apple ID stop opening after 7 days and need to be run from Xcode again.
- A free Apple ID allows only 3 sideloaded apps at once, and the owner already has 3 (Tinnitus, Do Now, Track Miles).
- Audio can only really be judged on the iPhone with headphones, not in the Simulator.
