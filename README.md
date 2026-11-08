# Utu

*Utu* is te reo Māori for reciprocity: restoring balance after a wrong.

A guild-run kill-on-sight list and bounty game for open-world PvP in WoW: Forever.

Guildies mark gankers, bounties grow with marks and ganks and cool off over time, and hunters climb a seasonal leaderboard by claiming kills. Everything syncs between guild members over hidden addon messages.

**Player guide and rules:** [Utu/README.md](Utu/README.md)

## Install

Download the zip from [Releases](../../releases) and unzip it into `World of Warcraft/<client>/Interface/AddOns/`, so you end up with `Interface/AddOns/Utu/Utu.toc`.

## Development

| | |
|---|---|
| `Utu/` | The addon itself. Load order is in `Utu.toc`. |
| `tests/harness.lua` | A mock of the WoW API that runs several clients on a shared message bus with a virtual clock. Set `H.forever = true` to mock WoW: Forever (no combat log, secret values via `H.SECRET`). |
| `tests/run.lua` | The test suite. |
| `build.sh` | Packages `dist/Utu-<version>.zip`. |

Run the tests with Lua 5.1:

```sh
lua5.1 tests/run.lua           # all tests
lua5.1 tests/run.lua "pardon"  # only tests whose name contains "pardon"
```

The mock can't catch missing UI templates, protected-frame errors or real-client API differences. Before a release, also test in game with `/console scriptErrors 1`, and run `/kos probe` near an enemy player.

WoW: Forever runs on the Midnight engine: no combat log for addons, and some unit fields come back as secret values. All unit reads go through `KOS:UnitInfo` (`Caps.lua`), which drops secrets, and features check `KOS.caps`. Handler errors and probe results are saved to `UtuDB.diag` / `UtuDB.probe`.

### Releasing

1. Bump `## Version:` in `Utu/Utu.toc`.
2. Tag the commit to match the version, e.g. `git tag v0.4.0 && git push --tags`.
3. CI runs the tests, builds the zip and attaches it to a GitHub release.

## Licence

[MIT](LICENSE)
