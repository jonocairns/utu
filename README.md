<p align="center"><img src="media/utu-logo.png" alt="Utu logo: a pūkana face" width="160"></p>

# Utu

*Utu* is te reo Māori for reciprocity: restoring balance after a wrong.

A guild-run kill-on-sight list and bounty game for open-world PvP in WoW: Forever.

Guildies mark gankers, bounties grow with marks and ganks and cool off over time, and hunters climb a seasonal leaderboard by claiming kills. Everything syncs between guild members over hidden addon messages.

**Player guide and rules:** [Utu/README.md](Utu/README.md)

## Install

**With WowUp (updates itself):** in WowUp, pick your WoW: Forever install, go to **Get Addons → Install from URL**, paste `https://github.com/jonocairns/utu` and install. Then turn on **Auto update** for Utu in My Addons (WowUp leaves it off for Forever by default).

**By hand:** download the zip from [Releases](https://github.com/jonocairns/utu/releases/latest) and unzip it into `World of Warcraft/_forever_/Interface/AddOns/`, so you end up with `Interface/AddOns/Utu/Utu.toc`.

## Development

| | |
|---|---|
| `Utu/` | The addon itself. Load order is in `Utu.toc`. |
| `Utu/Libs/` | Embedded standard libraries: LibStub, CallbackHandler, LibDataBroker and LibDBIcon (the minimap button), ChatThrottleLib (shares addon-message bandwidth with other addons). See `Utu/Libs/README.md`. The test harness stubs them. |
| `.luacheckrc` | Lint config. |
| `tests/harness.lua` | A mock of the WoW API that runs several clients on a shared message bus with a virtual clock. Set `H.forever = true` to mock WoW: Forever (no combat log, secret values via `H.SECRET`). |
| `tests/run.lua` | The test suite. |
| `build.sh` | Packages `dist/Utu-<version>.zip` and `dist/release.json`, and turns the top of `CHANGELOG.md` into `dist/notes.md` and `Utu/WhatsNew.lua`. |
| `AGENTS.md` | Repo conventions and common pitfalls, for contributors and coding agents. |
| `CHANGELOG.md` | What changed in each version, for players. The one source for release notes, WowUp's changelog and the in-game "What's new". |

Run the tests with Lua 5.1:

```sh
lua5.1 tests/run.lua           # all tests
lua5.1 tests/run.lua "pardon"  # only tests whose name contains "pardon"
```

Lint with [luacheck](https://github.com/lunarmodules/luacheck) before committing; it should report 0 warnings:

```sh
luacheck Utu
```

The mock can't catch missing UI templates, protected-frame errors or real-client API differences. Before a release, also test in game with `/console scriptErrors 1`, and run `/kos probe` near an enemy player.

WoW: Forever runs on the Midnight engine: no combat log for addons, and some unit fields come back as secret values. All unit reads go through `KOS:UnitInfo` (`Caps.lua`), which drops secrets, and features check `KOS.caps`. Handler errors and probe results are saved to `UtuDB.diag` / `UtuDB.probe`.

### Releasing

1. Bump `## Version:` in `Utu/Utu.toc` and add a matching `## x.y.z` section at the top of `CHANGELOG.md`.
2. Run `./build.sh` (it checks the two match and regenerates `Utu/WhatsNew.lua`), then commit and push.
3. `git tag -a vX.Y.Z -m "Utu vX.Y.Z" && git push --tags`. CI tests, builds and publishes the release with the changelog notes.

WowUp needs `release.json` attached, checks the five newest releases, and shows the newest one's notes. Players who skip versions see what they missed in game (`/utu news`).

Conventions and pitfalls: [AGENTS.md](AGENTS.md).

## Licence

[MIT](LICENSE)
