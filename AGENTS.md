- Utu is a World of Warcraft addon for **WoW: Forever** (client 1.60.x, `## Interface: 16001`, built on the Midnight engine). It's on trial with a few guildies, so changes reach real players through WowUp within hours of a release.
- The app is called **Utu** (te reo Māori: reciprocity). "Kill on Sight" survives only as the name of the list status in the UI ("Mark as Kill on Sight..."). The internal Lua table is still `KOS`, the comm prefix is still `KOS2`, and `/kos` remains an alias of `/utu`; leave those names alone.

- Commit straight to `main`. There are no PRs or release bot for now. Write commit subjects as plain sentences about what changed (`Manage muted guildies from the UI`), not conventional prefixes.
- Ship every player-visible change as a release; WowUp only sees releases, not commits.
- Release steps:
  1. Bump `## Version:` in `Utu/Utu.toc`.
  2. Add a matching `## x.y.z` section at the top of `CHANGELOG.md`.
  3. Run `./build.sh` and commit the regenerated `Utu/WhatsNew.lua` with the release.
  4. Push `main`, then `git tag -a vX.Y.Z -m "Utu vX.Y.Z" && git push --tags`.
  5. CI runs the tests, builds, and publishes the release with the changelog section as its notes.
- `CHANGELOG.md` is the one source for player-facing notes. Its top section becomes the GitHub release body (which WowUp shows as the changelog), and `Utu/WhatsNew.lua` (the chat message on the first login after an update, and `/utu news`).
  - Write bullets for players, not developers: what they'll notice and what to do. Lead with a bold phrase for the headline change.
  - Leave out internal refactors.
  - `build.sh` refuses to build if the top section doesn't match the toc version, and a test checks `WhatsNew.lua` is current.
- Always attach both `Utu-x.y.z.zip` and `release.json` to a release. WowUp only offers a GitHub release to a Forever install if `release.json` lists the zip under the `forever` flavour, and it looks at the five newest releases only. Never delete or retag a published version; ship a new patch instead.
- The maintainer's own install is managed by WowUp. Don't copy builds into the game's `Interface/AddOns` folder or make loose zips; publish a release.

- Validate before every commit:
  - `lua5.1 tests/run.lua` (all tests pass), or `lua5.1 tests/run.lua "name"` for a subset.
  - `luacheck Utu`: 0 warnings, the same as CI.
  - If the tools aren't on `PATH`, run them through `nix shell nixpkgs#lua5_1 nixpkgs#lua51Packages.luacheck -c ...` (the interpreter is then `lua`).
- `tests/harness.lua` mocks the WoW API and runs several clients on a shared guild message bus with a virtual clock. It loads files in `Utu.toc` order and stubs the embedded libraries. Add a test for new behaviour and for every bug fix.
- The mock can't catch missing UI templates, protected-frame (taint) errors, layout overflow, or real-client API differences. Say what still needs checking in game when you hand work back, rather than claiming it works.
- Code that depends on game APIs the harness lacks (for example `MenuUtil`, `Menu.ModifyMenu`) must fall back gracefully when they're missing.
- Add new WoW globals to `.luacheckrc` (`read_globals`, or `globals` for ones Utu defines) instead of silencing the warning inline.

- Forever is not Classic Era. Addons get no combat log, and some unit fields come back as secret values (`issecretvalue`). Read units only through `KOS:UnitInfo` (`Caps.lua`), which drops secrets, and gate features on `KOS.caps`. Kills are inferred from honour gains, nameplates, target and mouseover.
- Forever names can contain a space. `UnitName` returns the second word of a two-word name as the realm ("Pi", "Target"). Real Forever realm names contain digits (`CAMWOWAU1Realm2PvP`), so `KOS:JoinSpacedName` joins letters-only "realms" back into the name. Always pass names through `KOS:Canonical`, which also capitalises each word as the game does.
- `GetGuildInfoText` is blocked in combat; use the cached `KOS:GuildInfoText()`.
- Hovering, menus and secure frames can taint in combat. Check `InCombatLockdown()` before touching protected UI.

- Treat the sync protocol as a contract with older versions still running in the guild. Messages are tab-separated over prefix `KOS2` on the GUILD channel, one tag per message type.
  - Only add fields at the end; never reorder, repurpose or remove fields.
  - Keep each message within 255 bytes (`KOS.NOTE_MAX` exists for this).
  - Unknown tags and extra fields must be ignored, not errors.
  - Send through the queue in `Sync.lua`, which uses ChatThrottleLib: live events at NORMAL, bulk sync at BULK.
- Saved data lives in `UtuDB`. Migrations go in `KOS:InitDB` and must be idempotent, safe to run on every load and on data from any earlier version. Guard each one with a version field (`feedVersion`, `seenVersion`) or a shape check.
- Personal settings (`db.settings`, including mutes) are never synced. Muting is personal: it hides a guildie's marks and sightings for you only, and never changes bounties, points or anything sent to others.

- Text never spills out of its frame. Give every font string a width bounded by its container, and choose wrapping (`SetWordWrap`, max lines) or truncation deliberately. When adding a line to an existing panel, check the space is free: the Settings page's first column is already full.
- `Utu/Libs/` holds unmodified upstream copies of LibStub, CallbackHandler, LibDataBroker, LibDBIcon and ChatThrottleLib, each under its own licence (`Utu/Libs/README.md`). Don't edit them; update by replacing the whole folder. luacheck skips them.
- The minimap button is a LibDBIcon launcher named `Utu`. Minimap-button collectors (EllesmereUI, OneForAll) manage it; problems with it are usually caused by a collector, not by Utu.

- The logo (`Utu/Media/logo.tga`, masters in `media/`) is a pūkana face supplied by the maintainer.
  - Don't generate replacement Māori designs (tā moko, tekoteko, whetero faces). If new artwork is needed, ask the maintainer.
  - Don't imitate other teams' or brands' marks (for example the NZ Warriors logo).
- The GitHub thumbnail WowUp shows is the repo owner's avatar, not something the repo controls.

This file records repo standards, common mistakes and recurring points of confusion for future agents. Keep entries durable, current and decision-oriented: prefer reusable rules over one-off bug stories or roadmap notes, and update or delete an entry when the code changes under it.
