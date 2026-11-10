# Turn Tactics · v0.1

Mobile-first, dependency-free PWA foundation based on the supplied game documents.

## Run locally

Requires Node 18+ for tests and Python 3 for the development server.

```sh
npm test
npm start
```

Open http://localhost:8080. No npm install or build step required. A phone cannot reach the computer through its own localhost: use an HTTPS test deployment for phone installation tests.

## What works

5–20 player setup, randomized unique spawns, configurable board size, three hearts and one opening point, orthogonal movement, range-based attacks and point transfers, shields, persistent range upgrades, elimination and self-removal, eliminated-player majority voting, saved local sessions, manual day advancement, default last-survivor victory, PWA manifest and offline app shell.

**Host-only local prototype. Not multiplayer.** All data is visible in browser storage. Do not share a host device with players expecting secrecy. No accounts, remote synchronization, automatic scheduling, image uploads, or rule-change proposals yet. The log displays only the most recent 100 entries but the local state retains all entries. Clearing site data deletes the session. No export/import yet.

## Provisional rules (need designer confirmation)

- Default board is (N−1) × (N−1). Source wording is ambiguous.
- One tile per Move; occupied tiles block movement.
- Base range is Manhattan distance 2; attack/gift share it; upgrades persist.
- Gifts transfer one point total, not one point plus a fee.
- Failed actions spend nothing, unlike the draft's unclear declaration penalty.
- Shielded targets reject attacks without a charge.
- Vote award requires strictly more than half of ballots cast, not merely the highest count. No bonus for a tie/plurality. Ballots reset daily.
- Host manually closes actions and advances days; no real midnight/7pm enforcement.
- Only default last-player-standing victory exists. Host-approved Add Change action (4 points) is intentionally unimplemented until its scope and approval/refund policy are specified.
- Board uses numbered tokens with names in player selectors and accessible labels. Custom image icons are deferred.

## GitHub and Bunny deployment

This archive is ready to commit to a GitHub repository; it has NOT been uploaded or deployed. Do not commit secrets.

1. Create a repository and commit this folder.
2. For static hosting, upload **the contents of `public/`**, including icons and manifest. Do not expose private files or credentials in that directory.
3. Configure the Bunny storage/origin and CDN delivery endpoint using the provider's current dashboard. A b-cdn.net delivery hostname needs an origin serving these files; a GitHub repository by itself is not a production static origin. GitHub push-to-deploy automation is not configured.
4. Serve over HTTPS, ensure `/` serves `index.html`, and serve `.js` as JavaScript and `.webmanifest` as `application/manifest+json` (or compatible JSON MIME type).
5. Keep `sw.js` revalidated (Cache-Control: no-cache), avoid long immutable caching for unversioned HTML/JS/CSS, and purge stale CDN copies after updates. Increment the worker cache version and asset list when changing app files.
6. Test Safari/iPhone and Chrome/Android on the actual HTTPS hostname. Local Chromium tests do not certify mobile installation behavior.

No backend or secret keys are needed for this prototype. A CDN is delivery infrastructure, not by itself a trusted game server/database.

## Multiplayer architecture (next phase)

Keep static UI on Bunny; use a separately authenticated API and persistent database for rooms and authoritative state. Backend choice is not committed yet. The server must enforce role-based projections (never send private host state to players), validate every action and point balance, timestamp/order actions, apply game-timezone midnight income exactly once, close actions at 19:00, expire shields, and process host rule approvals and votes transactionally. A client's clock or localStorage must never decide these outcomes. Offline multiplayer actions must not be represented as accepted.

Suggested implementation sequence: room creation + host/player authentication → authoritative transactional action endpoint → public/private views → midnight scheduler → custom icons + host rule proposals → deployment and device testing.

## Structure

- `public/engine.js`: pure, tested local rules
- `public/app.js`: UI and local persistence
- `public/style.css`: responsive light/dark interface
- `public/manifest.webmanifest`, `public/sw.js`: home-screen/offline foundation
- `tests/engine.test.js`: rules regression tests

No original PDF files are redistributed in this archive.
