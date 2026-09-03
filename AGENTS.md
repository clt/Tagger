# Repository Guidelines

## Scope and priorities

This file applies to the entire repository. Tagger is a native macOS 14 SwiftUI
application for browsing MP3 folders and editing ID3 metadata. Protecting users'
audio files takes priority over convenience: writes must be explicit, validated,
and covered by tests that operate only on disposable fixtures.

## Project map

- `Tagger/App` contains the application and scene entry points.
- `Tagger/Stores/LibrarySession.swift` is the main-actor source of truth for
  navigation, selection, drafts, save state, and user-facing errors.
- `Tagger/Services` owns folder access, filesystem operations, and ID3 I/O.
  Keep these services behind protocols when they need test doubles.
- `Tagger/Models` contains value types for directory entries and edit drafts.
- `Tagger/Views` should remain declarative; move filesystem and metadata logic
  into stores or services.
- `Tagger/Support` contains commands, AppKit interop, and close/quit safeguards.
- `TaggerTests` contains unit and filesystem integration tests.
- `project.yml` is the source of truth for the checked-in Xcode project.

## Build and test workflow

Use the project scripts from the repository root. They select the installed
Xcode app and keep Derived Data under `.build/`.

```sh
./script/test.sh
./script/check_project.sh
./script/build_and_run.sh
```

After changing `project.yml` or adding/removing source files, run
`./script/generate_project.sh` and commit the resulting Xcode project changes.
Never hand-edit generated `project.pbxproj` content. Run `git diff --check` and
both test/check scripts before submitting a pull request.

`build_and_run.sh` stops processes named `Tagger` before launching the new
build. Do not run it when another Tagger instance may contain unsaved work.

## Swift conventions

- Keep the project compatible with Swift 6 strict concurrency.
- Keep observable UI state and navigation on `@MainActor`; perform file and ID3
  work asynchronously in the existing actor-based services.
- Prefer small value types, explicit error cases, dependency injection through
  protocols, and focused async tests.
- Preserve cancellation and generation checks around asynchronous folder and
  tag loads, along with folders-first localized filename ordering.
- Preserve macOS conventions, keyboard support, VoiceOver labels, and clear
  disabled/loading states when changing SwiftUI views.
- Do not hide write failures. Surface actionable errors through
  `PresentedError` and preserve any remaining unsaved draft state.

## Audio and filesystem safety invariants

- Never auto-save metadata or filenames. Save, Revert, navigation guards, and
  close/quit guards must agree about dirty state.
- Validate an `AudioFileSnapshot` immediately before writing so external edits
  are not overwritten.
- Preserve audio bytes, supported ID3v2.3/v2.4 versions, and unknown frames
  whenever the underlying AudioMarker operation supports doing so. Continue to
  reject unsupported or malformed tags without modifying the file.
- Filename editing is single-file only. Preserve the original MP3 extension,
  reject invalid or overlong names and symlink sources, handle case-only
  renames, and never overwrite an existing entry, including a dangling symlink.
- When tags and a filename both change, save tags before renaming. If renaming
  then fails, retain the successful tag save and report the partial result.
- Batch fields change only when their Apply control is enabled. Batch writes are
  sequential, never rename files, and may partially succeed; report per-file
  failures accurately rather than rolling back earlier successes.
- Keep hidden items, packages, and symbolic links out of folder browsing unless
  a future feature explicitly defines safe behavior for them.
- Maintain balanced security-scoped resource access and durable bookmark
  restoration for user-selected folders.

Use generated or copied MP3 fixtures for write tests. Tests that rename or save
files should assert both metadata behavior and preservation of unrelated bytes.
Never point automated tests at a user's music library.

## Dependencies, documentation, and licensing

AudioMarker is pinned exactly in `project.yml`. Keep third-party licenses and
notices synchronized with dependency changes. Update the README when behavior,
limitations, requirements, or screenshots change. Tagger source is MIT licensed.

## GitHub workflow

Do not push directly to `main`. Create a focused branch and pull request; the
default-branch ruleset requires an `@clt` code-owner review and blocks deletion
and force-pushes. Only merge a pull request when the user explicitly requests
it. Do not commit `.build/`, Derived Data, `xcuserdata`, or local media files.
