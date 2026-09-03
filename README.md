# Tagger

Tagger is a small native macOS app for browsing folders of MP3 files and editing common ID3 tags.

## Current feature set

- Three-column folder tree, file list, and tag editor
- Single-file editing plus Finder-style multi-selection for batch editing
- Mixed-value protection: batch saves change only fields explicitly marked Apply
- ID3v2.3 and ID3v2.4 reading and writing
- Title, artist, album, album artist, track, disc, year, genre, composer, comment, lyrics, and artwork
- Explicit Save and Revert controls, including Command-S
- Save/discard/cancel confirmation before navigating away, closing, or quitting
- Sandboxed access to user-selected folders, remembered between launches
- Protection against overwriting externally changed, unsupported ID3v2.2, or malformed tags

## Build and run

The project requires a Swift 6.2-or-newer Xcode toolchain. It currently defaults
to `/Applications/Xcode-beta.app`, then falls back to `/Applications/Xcode.app`.
Set `TAGGER_XCODE_APP` to use another installation.

Open `Tagger.xcodeproj` in Xcode, or run:

```sh
./script/build_and_run.sh
```

Run the test suite with:

```sh
./script/test.sh
```

The checked-in Xcode project is generated from `project.yml`. After changing the project specification, regenerate it with:

```sh
./script/generate_project.sh
```

Verify that the generated project has not drifted from the specification with:

```sh
./script/check_project.sh
```

Current Debug and Release configurations use a placeholder bundle identifier and
local ad-hoc signing. Choose your own reverse-DNS identifier, development team,
and distribution signing settings in `project.yml` before sharing the app.

## Initial-version limitations

Batch editing works on MP3 files in the currently displayed folder; use Command-click or Shift-click to select them. Batch saves are sequential, and a failed file does not roll back files already saved. The editor exposes one primary artwork image, one comment, plain lyrics, integer track/disc numbers without totals, and a four-digit year. Saving may collapse multiple artwork, comment, or lyrics variants into the displayed primary value, so test with copies before using irreplaceable files.

Tag support is provided by the Apache-2.0-licensed AudioMarker 0.1.1 package, pinned exactly for repeatable builds.
