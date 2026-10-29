# Connectivity and synchronization controls

Implemented at the owner's request: an application-wide offline banner and a
manual synchronization control alongside automatic synchronization.

- `NetworkConnection` uses Network framework path monitoring on a dedicated
  queue and publishes state on MainActor. An unsatisfied path shows the localized
  top banner. A satisfied path indicates network availability, not proof that the
  API or public internet is reachable. Connection-on-demand paths remain unknown
  so a user request can establish the connection.
- The main application window shows **Sin conexión a internet** / **You're
  offline. No internet connection.** The banner wraps for larger text sizes and
  does not block navigation or remove stored records.
- Signed-in users with invoice-view access have **Sincronizar ahora** / **Sync
  now** in the toolbar. The action is disabled while offline or already running.
- Automatic synchronization runs when an authorized, active window gains a
  network connection, returns to the foreground or finishes signing in. This is
  foreground best-effort behavior, not continuous background execution.
- The same service downloads the first invoice page, previously saved pages and
  previously downloaded detail records. Each page commits atomically to SQLite.
  Finished synchronization reloads visible list/detail content from SQLite, including committed partial progress when a later request fails.
- Concurrent windows share synchronization status. Duplicate runs are prevented;
  reconnects arriving during an unsuccessful attempt can make a fresh attempt
  after it finishes. Old sessions cannot publish success into a replacement
  session. Failed/canceled runs never become successful synchronization markers.
- Progress and failure messages are localized. Failures preserve stored records
  and offer the same manual action for retry. Missing records are not treated as
  deletion confirmations.

## Current limits

Invoice description edits now have a transactional outbox and explicit conflict
review. Synchronization uploads pending immutable requests before downloading.
Review-required edits do not prevent safe download refreshes and are reported as
requiring attention. Network failures retain queued work for the next attempt.
The separate conditional API routes must be deployed before uploads can succeed;
an unavailable route never triggers an unconditional mutation fallback.

Saving an edit requests an upload-only run, avoiding a full cache refresh on
every save. A request arriving during an existing run remains outstanding until
a later run includes it. Manual, foreground and reconnect requests include
downloads; an upload-only completion cannot satisfy a requested full refresh.
Pending changes, their status and manual retry are visible from the invoice list.

Creation, broader editing, attachments, field operations and best-effort system
background execution remain incomplete. No arbitrary offline access cutoff is
applied. See invoice-persistence.md for exact editing/recovery boundaries.

Already-authorized users can open local invoice storage without a token refresh.
Offline relaunch can restore a previously verified context from Keychain after a recognized connection failure; see authentication.md for the exact boundaries and remaining signed-runtime checks. The native macOS Keychain capability is approved and configured.

Regression tests cover synchronization success/failure/retry, overlapping
requests, session replacement, cancellation, and refreshing cached pages/details.
Physical network transitions and visual/accessibility behavior of the new banner
remain manual acceptance checks; automated tests do not prove those UI behaviors.
