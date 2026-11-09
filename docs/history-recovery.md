# Local capture recovery and downgrades

History saves publish a new revision only after its image and editable data have
been written. The index selects the current revision. A failed or interrupted
save can leave an unpublished revision on disk; the app does not automatically
promote it or delete its full capture files.

## Before recovering files

Quit macshot normally and let pending saves finish. Make a copy of the entire
history directory, including `index.json`, before changing anything. The normal
sandboxed app uses:

`~/Library/Containers/com.sw33tlie.macshot.macshot/Data/Library/Application Support/com.sw33tlie.macshot/history`

An older, unsandboxed installation may instead have used:

`~/Library/Application Support/com.sw33tlie.macshot/history`

Use the directory containing the captures from the installation being recovered.
These instructions do not require modifying the index or deleting the source.

## Recover a capture as an ordinary image

1. For a current entry, find its `id` and `revision` in the copied `index.json`.
   Its full capture is `<id>/<revision>/image.png`. Entries without a revision
   use the older flat layout, `<id>.<fileExtension>`.
2. Copy that full image to another folder with a distinct filename. Open the copy
   in Preview or macshot and check its appearance and dimensions. This image
   includes the saved annotations and effects; `raw.png` does not. `preview.png`
   and `thumb.png` are smaller caches.
3. If the index is missing or a save was interrupted, inspect the full images in
   the revision folders in the backup. An unindexed revision is only a recovery
   candidate; it is not proof that the save completed or that it is the version
   the user intended. Keep the files until the right capture has been identified.

The app opens the flattened image when editable data is unreadable, rather than
opening the raw image with an omitted annotation or effect. Optional sidecars
were not recorded separately in the index: if one is missing while another is
valid, the app cannot distinguish deletion from a legitimate annotations-only
or effects-only capture. Recover from a backup when that distinction matters.

## Returning to an older macshot build

Builds from before the revision layout look for flat image filenames. They cannot
read newly written revision directories merely by opening the current index.
There is no automatic downgrade conversion.

Before downgrading, recover any newer captures as ordinary full-size images and
back up the entire current history. With macshot closed, restore a complete
history backup made by the older build to its original location. Keep the newer
history backup separately; do not merge its index into the old backup. Reimporting
a flattened image preserves its appearance but does not restore editable objects.

For the local installation made during this review, pre-install backups are in
`~/Library/Application Support/macshot-local-build-backups/c4b86a8-20260920-020927/`.
The `sandbox-history` and `legacy-history` folders correspond to the two locations
above. This is a local development backup, not a backup made by every app update.

## What has been checked

The isolated sandboxed probe was terminated after a new revision was written but
before its index was published. On relaunch, the prior committed captures were
unchanged and decoded, while the unpublished revision remained available on
disk. Unit tests also cover failed publication and legacy flat-file loading.
This verifies process interruption at that boundary; sudden power loss, damaged
storage, and a recovery browser are not covered by this check.
