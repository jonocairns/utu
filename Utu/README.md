# Utu

*Utu* is te reo Māori for reciprocity: restoring balance after a wrong. Here, it's a guild-run kill-on-sight list and bounty game for open-world PvP on WoW: Forever.

- **Mark gankers.** Bounties grow with marks and ganks, and cool off when the ganking stops.
- **Get warned** when a marked player is nearby, and call guildies for help.
- **Claim kills** for points, and climb the seasonal hunter leaderboard.

Open it with `/utu`, the minimap button, or the addons dropdown by the minimap. Settings are in the window.

## Install with WowUp

WowUp keeps Utu up to date for you.

1. Install [WowUp](https://wowup.io) (the CurseForge edition, WowUp-CF) and open it.
2. Pick **World of Warcraft: Forever** in the game dropdown at the top. If it isn't listed, add it under **Options → World of Warcraft** by choosing `World of Warcraft\_forever_\Wow.exe`.
3. Go to **Get Addons**, click **Install from URL**, paste `https://github.com/jonocairns/utu`, then **Import** and **Install**.
4. In **My Addons**, right-click **Utu** and tick **Auto Update**. WowUp leaves this off for Forever addons by default.
5. Restart the game, or `/reload` if it was already running.

After that, new versions install themselves while WowUp is running, or click **Update** in My Addons. If you'd installed Utu by hand before, delete `Interface/AddOns/Utu` before step 3, so WowUp manages it.

**By hand instead:** unzip the latest [release](https://github.com/jonocairns/utu/releases/latest) into `World of Warcraft/_forever_/Interface/AddOns/`, so you have `AddOns/Utu/Utu.toc`.

**Turn on enemy nameplates (V).** They're the main way Utu spots players.

## How it works

| | |
|---|---|
| **Bounty** | Each guildie's mark adds 100, and each guildie they kill (a gank) adds 100. Repeat ganks on the same person in a week count less each time. The bounty halves every 14 days, and drops 50 per claimed kill. |
| **Level** | Lv 1 and up: Suspect 1+, Marked 4+, Wanted 8+, Most Wanted 14+, Notorious 20+, Public Enemy 28+, Legendary 40+. Marks expire after about 8 weeks unless refreshed. |
| **Kill value** | **5 + 3 × level** for the killing blow, ignoring your own marks and deaths (no farming alts). Worth nothing if they're 10+ levels below you. **+50% each** for Top Bounty, revenge (they killed a guildie in the last hour) or rescue (answering a help call), and first blood (your first kill of them this season). Grouped guildies who hit them in the last 20 seconds get half. |
| **On Forever** | Addons get no combat log, so kills come from honour gains, and grey kills don't score. After you die, a prompt lists who was targeting you: pick whoever ganked you to mark them. |
| **Help calls** | Sent when a marked player, or anyone 5+ levels above you, attacks you. Or call by hand with `/utu sos` or a key binding. Guildies nearby (400 yd by default) get a banner with the direction and an **On my way** button. Killing the attacker within 3 minutes pays +50%. |
| **Seasons** | Every 8 weeks the leaderboard resets. Hunter ranks run from Tracker I to Grim Reaper, then Legend N, and there are badges along the way. |
| **Enemy guilds** | A guild's bounty is the sum of its members'. The whole guild becomes kill on sight at guild Lv 30 with 10+ ganks on us. |
| **Battlegrounds** | Don't count. |

## Staying out of your way

- You're alerted when a marked player arrives, not the whole time they're around. Several at once become one banner.
- Players under bounty Lv 3 don't alert, unless you marked them. Battlegrounds and arenas are quiet.
- Guild events go to the **Activity** tab. Chat only shows what's about you, near you, or big news.
- **Mute a guildie** whose marks you don't care about: right-click their name, use **Mute...** under a player's marks, or the **Muted** button in Activity. It's just for you: bounties and points don't change.
- Entering a zone where guildies were recently ganked shows one threat toast.

## Officers

The **Officer** tab sets guild-wide rules: who can mark and pardon, the guild kill-on-sight level, bounty half-life and season length. They're saved in the guild info, so everyone gets the same rules. It also reviews suspicious claims (`farm?`, `inflated?`) and can strike them for everyone.

## Help

- **What changed?** The first login after an update lists it in chat, and `/utu news` shows it again. Every version is in the [changelog](../CHANGELOG.md).
- **Marks not syncing?** Both of you need to be online. `/utu sync` shows what was sent and who you've heard from.
- **Names with spaces:** use quotes in commands: `/utu add "Kind Eyes" camps the flight path`.
- **Shows as out of date?** Make sure you're on the latest version. Forever 1.60.1 is interface `16001`.
- **Commands:** `/utu help`. Claims are self-reported, and officer review is the check.
