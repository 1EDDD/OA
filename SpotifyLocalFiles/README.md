# SpotifyLocalFiles

A LiveContainer-compatible Spotify 9.0.48 tweak.

The tweak adds a small local-files control to Spotify, lets you choose audio from Files, stores it inside the guest container, reads basic metadata, associates the file with the current screen title as a local playlist key, and plays the file locally.

It does not modify Spotify's server-side playlist database.

GitHub Actions builds the unsigned dylib on a macOS runner. No Mac, Xcode, jailbreak, or Theos installation on the iPhone is required.

Build outputs:
- SpotifyLocalFiles.dylib
- SpotifyLocalFiles.plist
- Theos package

For LiveContainer, import the dylib through its tweak manager and use an app-specific tweak folder for Spotify.
