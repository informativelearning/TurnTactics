# Turn Tactics online alpha · v0.2 add-on

This adds an online route without replacing your v0.1 files. **It is a private-playtest alpha, not a production-ready launch.**

## Hosting recommendation

Keep Vercel while developing: your GitHub integration already works. Keep the static frontend portable to Bunny Storage + a Pull Zone (`yourname.b-cdn.net`) later. The backend is Supabase in either case. No Vercel server functions, CLI, local build, or paid app-store account are needed.

## Chromebook / browser-only installation

1. Create a **new, dedicated** Supabase project. Save its database password privately; do not add it to GitHub or chat.
2. In Authentication settings, enable **Anonymous Sign-Ins**. This uses a browser-bound identity, not email accounts. Don’t enable this on an unrelated production project.
3. Open SQL Editor → New query. Paste `supabase/001_online.sql` and run it **once**. It creates only `tt_` tables/functions. Don’t rerun it against an existing schema; do not drop tables to solve an error. Send the error text (without credentials) instead.
4. Run `supabase/002_smoke_test.sql` separately. It exercises authorization, private/public projections, minimum players, unique spawns, actions, request deduplication, voting, and day processing in a transaction that rolls back its test data. It should finish without an exception. **This SQL suite has not been executed against your Supabase project by the assistant.** If it fails, stop and share the error before inviting players.
5. In Supabase’s Connect/API settings, copy the **project URL** and **publishable key** (legacy anon key is also compatible). Set the two exports in `public/online-config.js`. These are intended for browser use with the restricted RPC permissions in the migration. **Never use a secret key, service_role key, JWT signing key, database URL, or database password.**
6. On GitHub, upload the contents of this add-on’s `public/` folder **into your repository’s existing `public/` folder**. Don’t create `public/public/`. Keep your existing local prototype and icon files. Add `supabase/` and this setup document at repository root, not inside `public/`.
7. Commit the files. Vercel should deploy your connected branch. Open **https://turntactics.vercel.app/online.html** after the deployment is ready. It is a new route; the home page remains your old local prototype. No build or output setting changes are required.
8. Click **Connect this browser**, then **Create host room**. Share the 12-character code privately. Other browsers click Connect, enter a name/code, and join. Start with at least five players. The host is a separate referee, not a player. For testing, use separate browser profiles/devices: multiple tabs in the same profile share one identity.

No integration or account was created on your behalf. Nothing in this add-on has been pushed or deployed automatically.

## Included in this step

- Shared lobby with a referee and 5–20 players; host chooses board size before starting.
- Server-generated random unique spawns and server-held resources.
- Server-validated move, attack, give, shield, persistent range upgrade, withdrawal, and eliminated-player voting.
- Atomic commands serialized by a database row lock. Server acceptance order decides resolution; this does not guarantee the order users clicked across different networks.
- UUID idempotency for gameplay commands and retry button for ambiguous network failures. Pending UUID survives reloads in the same tab through sessionStorage; do not clear browser storage during a pending action. Room creation is not idempotent: if creation loses confirmation, inspect the dashboard before creating again.
- Participant-only room snapshots. Public positions, names, eliminated status, movements, and final-blow announcements. Only self/host receives hearts, points, range, and shield status. Account IDs and ballots are stripped from snapshots. Host alone gets the private action log. “Private” means hidden from other players, **not** from host/database administrators.
- Four-second polling, not instantaneous WebSocket synchronization. Only server-confirmed actions update the board.
- New online home-screen manifest using existing project icons. No offline gameplay; initial online load also fetches a pinned Supabase JS client from esm.sh.

## Still intentionally deferred

- **Automatic midnight income / 19:00 cutoff and timezone enforcement.** Host closes actions and advances days manually. Each advance processes one day; repeatedly clicking advances multiple days. Do not claim the original daily schedule is enforced yet.
- **4-point Add Change** requests, approval/refund policy, and alternate win conditions.
- Custom uploaded image tokens and image moderation; numbered tokens remain for now. This does not yet reproduce the presentation’s player images.
- In-app chat/alliances; players can coordinate elsewhere without enforced loyalty.
- Persistent recoverable accounts, host recovery/transfer, room discovery, room deletion, export, and pagination.
- Public-launch abuse controls. Anonymous signup can be abused; configure CAPTCHA, rate limits, and a recovery-capable sign-in flow before public launch. This UI does not yet collect CAPTCHA tokens. Anonymous identities are lost when site data is cleared or a different device/domain is used. The current per-account five-room limit is not a substitute for signup abuse protection.

## Provisional rules carried forward

Board defaults to `(N−1) × (N−1)` but is configurable (the original wording is ambiguous). One orthogonal tile per movement point; occupied tiles block. Range is Manhattan distance 2, applies to attacks/gifts, and upgrades persist. Gifts cost exactly the point transferred. Invalid/blocked actions cost nothing. Shields reject attacks without charging. Votes require strictly more than half the eligible ballots cast; ties or pluralities give no bonus. Ballots for a target eliminated before the day advances are ignored. Original documents remain the design authority; these are explicitly provisional interpretations.

## Supabase security model

`tt_rooms` and `tt_requests` enable RLS and revoke direct table access from public/anon/authenticated. Only four authenticated RPCs are exposed; they check the caller, membership, host authority and action legality internally. Definer functions use an empty search path and schema-qualified table names. Do not add broad read policies or publish the private state table to Realtime. The browser must never receive the full state and merely hide private fields in CSS.

No production security audit or live concurrency/load test has been performed. Database functions need validation on your project using the included smoke suite and then a real multi-device playtest.

## Bunny migration later

Upload existing `public/` contents (including these new files, config and icons) to Bunny Storage, connect a Pull Zone, enable HTTPS, and configure GitHub deployment through Bunny’s supported workflow. Keep unversioned HTML/JS/CSS and `sw.js` revalidated or purge their CDN copies on updates; don’t cache authenticated Supabase API responses through Bunny. Keep the same Supabase project URL/key.

Moving to another hostname does **not** carry browser login storage or installed home-screen shortcuts with it. Because this alpha has no recovery-capable accounts, finish test rooms and reset/rejoin on the new host. Add recoverable login before migrating a running game. No Bunny credentials or GitHub Actions workflow are included yet.

## Verification performed / needed

JavaScript syntax, setup screen rendering, and simulated browser flows can be checked without your account. Mocked browser tests do not prove database security or actual device installation. Run the SQL suite, test unauthorized direct access and two-player action races on Supabase, then test on physical iPhone and Android before wider use.
