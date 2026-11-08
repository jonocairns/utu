# Kill on Sight

A guild-run bounty game for open-world PvP in WoW: Forever (Classic Era client and addon API).

Guildies mark gankers, bounties grow with marks and ganks and cool off over time, and hunters climb a seasonal leaderboard by claiming kills. Everything syncs between guild members over hidden addon messages.

**Player guide and rules:** [KillOnSight/README.md](KillOnSight/README.md)

## Install

Download the zip from [Releases](../../releases) and unzip it into `World of Warcraft/<client>/Interface/AddOns/`, so you end up with `Interface/AddOns/KillOnSight/KillOnSight.toc`.

## Development

| | |
|---|---|
| `KillOnSight/` | The addon itself. Load order is in `KillOnSight.toc`. |
| `tests/harness.lua` | A mock of the WoW API that runs several clients on a shared message bus with a virtual clock. |
| `tests/run.lua` | The test suite. |
| `build.sh` | Packages `dist/KillOnSight-<version>.zip`. |

Run the tests with Lua 5.1:

```sh
lua5.1 tests/run.lua           # all tests
lua5.1 tests/run.lua "pardon"  # only tests whose name contains "pardon"
```

The mock can't catch missing UI templates, protected-frame errors or real-client API differences. Before a release, also test in game with `/console scriptErrors 1`.

### Releasing

1. Bump `## Version:` in `KillOnSight/KillOnSight.toc`.
2. Tag the commit to match the version, e.g. `git tag v0.4.0 && git push --tags`.
3. CI runs the tests, builds the zip and attaches it to a GitHub release.

## Licence

[MIT](LICENSE)
