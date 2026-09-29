# Folder metadata summary layout QA

Design: a horizontal album header spanning the file list and editor, with a full-height folder tree.

The native SwiftUI implementation uses existing metadata, cover thumbnails, system fonts, and SF Symbols. Missing, mixed, loading, unreadable, and unsaved states remain supported. Metadata is written only through explicit Save.

Verification artifacts are in `.build/option1-preview/`; Xcode test output is in `.build/folder-summary-option1-tests.log`.

Verified the live app with populated and missing metadata, file selection, an unsaved album edit, and Revert. The header spans both content panes; the folder tree retains full height. Save remained explicit, and all tested audio hashes are unchanged.

Native offscreen captures passed at 1240×780 and 900×420. The narrow-layout alignment issue was corrected by constraining the inner split view to the available width and aligning the containing stack to its leading edge. No increased vertical minimum; measured content minimum is 851×10 before the app's existing 900×420 constraint.

All 172 tests pass through `./script/test.sh`; `./script/check_project.sh` and `git diff --check` pass. Live screenshots confirm the native folder selection renders normally; black selection and toolbar fade in the offscreen images are capture artifacts.

Final result: passed.
