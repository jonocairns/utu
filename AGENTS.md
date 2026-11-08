- Utu is a WoW: Forever addon (client 1.60.x, `## Interface: 16001`, Midnight engine), on trial with guildies who update through WowUp.
- The app is **Utu**. "Kill on Sight" is only the list-status label in the UI. Keep the internal names: the `KOS` table, comm prefix `KOS2`, and the `/kos` alias.

## Workflow
- Commit straight to `main` with plain-sentence subjects; no PRs or conventional prefixes for now.
- Ship player-visible changes as releases: follow README → Releasing. Never delete or retag a published version.
- Write `CHANGELOG.md` entries for players: what they'll notice, with a bold lead phrase. It feeds the release notes, WowUp's changelog and the in-game `/utu news`.
- Every release needs the zip and `release.json` attached, or WowUp won't offer it.
- The maintainer's install is WowUp-managed: don't copy builds into `Interface/AddOns`.

## Validation
- Before committing, run `lua5.1 tests/run.lua` (all tests must pass) and `luacheck Utu` (0 warnings).
  - If those aren't on `PATH`, use `nix shell nixpkgs#lua5_1 nixpkgs#lua51Packages.luacheck`.
- Add a test for each feature and each bug fix.
- The harness can't catch taint, missing templates, text overflow or real API differences. When handing work back, list what still needs checking in game.
- Guard APIs the harness lacks (`MenuUtil`, `Menu`) with a fallback.
- Add new WoW globals to `.luacheckrc`; don't silence warnings inline.

## Forever quirks
- No combat log for addons, and some unit fields are secret values.
  - Read units through `KOS:UnitInfo` and gate features on `KOS.caps`.
- `UnitName` splits two-word names into name and "realm" ("Pi", "Target"). Always normalise names with `KOS:Canonical`.
- `GetGuildInfoText` is blocked in combat: use `KOS:GuildInfoText()`.
- Check `InCombatLockdown()` before touching protected UI.

## Data and sync
- The `KOS2` message format is a contract with older clients still in the guild:
  - append fields, never reorder or remove them
  - stay under 255 bytes
  - ignore unknown tags
  - send through the `Sync.lua` queue
- `UtuDB` migrations go in `KOS:InitDB`. They must be idempotent and guarded by a version field or a shape check.
- Synced dumps can't prove who wrote an item, so each client checks dumped items in its own name against `UtuDB.authored` (`KOS:Ledger`). This only detects; it never changes what's merged. Any new way of creating my marks or claims must go through `KOS:Mark`/`Unmark`/`RecordClaim`, or call `LedgerVote`/`LedgerKill`.
- Personal settings, including mutes, are never synced. Muting never changes bounties or points.

## UI and assets
- Give every font string a bounded width, and choose wrap or truncate deliberately.
  - The Settings page's first column is full.
- `Utu/Libs/` holds unmodified upstream libraries. Replace them whole; never edit them.
- Minimap button problems usually come from button collectors (EllesmereUI, OneForAll), not Utu.
- The logo is the maintainer's pūkana artwork.
  - Don't generate Māori designs or imitate other brands' marks. Ask for new art instead.

Keep this file short, current and rule-shaped; delete entries the code no longer supports.
