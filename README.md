# Tinnitus

A personal iPhone app that measures the pitch, width, and loudness of your tinnitus, then plays sleep sounds or your own music with that frequency band notched out.

This is a personal tool, not a medical device.

## Layout

- `Tinnitus/` is the SwiftUI app (iOS 17 or later).
- `TinnitusCore/` is a Swift package with the audio math (tone and noise synthesis, biquad filters, pitch matching, profiles). It has no UI and is covered by unit tests.

## Build and run

1. Open `Tinnitus.xcodeproj` in Xcode 16 or later (Xcode 26 for an iPhone on iOS 26).
2. Select the **Tinnitus** target, open **Signing & Capabilities**, and pick your Apple ID team. With a free Apple ID you may need to change the bundle identifier to something unique.
3. Plug in your iPhone, select it as the run destination, and press Run. The first time, approve the developer on the phone under Settings > General > VPN & Device Management.

With a free Apple ID the app stops opening after 7 days. Run it from Xcode again to reinstall.

## Music

The Music tab plays songs you add from the Files app or from your Music library (songs you bought or synced). Each song is rendered once through the notch and cached, then the original and filtered copies play in sync so the notch toggle crossfades instantly. Apple Music streams and downloads are copy protected, so no app can filter them.

## Tests

```sh
cd TinnitusCore
swift test
```

## Research behind it

- Notch width: [Wunderlich et al., 2015](https://pmc.ncbi.nlm.nih.gov/articles/PMC4583393)
- Likeness-rating pitch matching: [Hébert, 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6583084)
- Narrowband noise as the test sound: [Wollbrink et al., 2019](https://en.fh-muenster.de/phy/labore/biotechnologie/downloads/Wollbrink_2019_-_Choice_of_test_stimulus_matters_for_pitch_matching_performanceComparison_between_pure_tone_and_narrow_band_noise.pdf)
