# Save profile selection

Canopy's title screen opens the selected logical profile through the existing
`CanopySaveStore`. Save management and Play use that exact store. The session
already binds its separate active-save and account-identity directories to the
native host; no runtime ABI or account format is added by this selector.

The original logical ID remains exactly `default`. A missing registry or title
selects it without writing metadata. Its hashed directory, save bytes, account
identity and backups are not renamed, copied or converted. New profile IDs are
original UUIDs encoded as 32 lowercase hex characters; display names are labels,
never filesystem names. Registration does not create a save/account directory.
Opening the real store creates its isolated empty layout. The existing native
account service initializes a new local account only if that profile is actually
launched. The selector never generates, imports, exports or copies account IDs.

`Metadata/save-profiles.json` has schema 1 and a bounded `titles` map. Each title
contains `selectedID` and up to 16 `profiles` records, each containing `identifier`
and `displayName`. The default record is always retained. Limits are 500 titles,
64 KiB per metadata file and 64 UTF-16 units per display name. Profiles cannot be
deleted or cloned in this slice. Unknown, invalid, linked, hardlinked, nonprivate
or oversized registry files are refused and preserved. Missing primary metadata
with a previous snapshot is treated as recovery, rather than an empty library.
Unmapped existing profile directories are never interpreted, swept or deleted.

Profile metadata is separate from `CanopySettings`: resetting game names and
preferences cannot erase profile selections or logical IDs. No imported game
metadata or filename may choose a profile or an account conversion policy.

Writes reread the complete registry under a private operation lock, merge other
titles, retain the verified old bytes as `save-profiles.previous.json`, and publish
through exclusive private staging files, file sync, rename and directory sync.
Known private paths use `O_NOFOLLOW_ANY` without opening readable descriptors for
system ancestors, which the iOS sandbox can deny. Creating the registry directory
uses its already known private parent and syncs that parent entry. Arbitrary
symlink ancestry remains refused before any directory is created.
An expected-selection check refuses stale screens. There is no automatic reset
or previous-snapshot restore; ambiguous/corrupt metadata requires explicit
recovery work. A failed rename preserves current metadata. A directory-sync
failure after rename can leave new metadata published: the error reports
`publicationUncertain`, the previous snapshot and live old store remain retained,
and Play is blocked until the user reloads the actual persisted selection.
Crashes can leave private staging files; this component does not sweep them.

Actual store opening and registry reads run on the serialized save queue. The
final bounded local selection commit and immediate store swap run together on
main after checking the operation epoch, foreground/visible controller, save
seal and global native-session ownership. Byte limits do not bound filesystem
or `fsync` wall time. Native startup cannot interleave with that final main-thread
commit. Delayed actions, backgrounding and dismissal invalidate the selection
epoch. Existing stores remain held on failed/canceled opens. Play rereads the
persisted logical ID before creating its session. Once native entry owns the
process, profile switching remains unavailable even if the main worker joins;
the account service and other runtime state are process-owned.

Run `python -m unittest discover -s tests -p test_canopy_profiles.py -v` on an
existing Apple Foundation environment. The original fixtures use the actual
registry and SaveStore for default/inode/identity/backup preservation, profile
isolation, exact-profile export refusal, restart persistence, preference-reset
isolation, stale selection, limits, unsafe inputs and real rename/sync failures.
The opener fixture denies readable ancestor-directory opens while allowing the
known container path and verifies actual registry creation/selection still works.
These tests do not establish UIKit/provider behavior, actual title save semantics
or device gameplay. Linux reports the Foundation tests as explicit skips.
