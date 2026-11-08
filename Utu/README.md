# Utu

*Utu* is te reo Māori for reciprocity: restoring balance after a wrong. Here, it's a guild-run kill-on-sight list and bounty game for open-world PvP, built for WoW: Forever.

- **Mark gankers.** Bounties grow with marks and ganks, and cool off when the ganking stops.
- **Get warned** when a marked player arrives nearby.
- **Claim kills** for points. Climb 50 hunter ranks each season.

Open it with `/utu` (or `/kos`), the minimap button, or the addons dropdown next to the minimap. Everything, settings included, is in the window. Slash commands are just shortcuts.

## Install

Copy `Utu` into `World of Warcraft/<client>/Interface/AddOns/`.

If the addon list shows it as *Incompatible* or *out of date*, run `/dump (select(4, GetBuildInfo()))` in game and put the number it prints on the `## Interface:` line of `Utu.toc`. (Forever 1.60.1 is `16001`.)

If something goes wrong, the addon saves its own errors (and `/kos probe` results) in `WTF/Account/<account>/SavedVariables/Utu.lua` after you log out or `/reload`.

**Turn on enemy nameplates (V).** They're the main long-range detection.

## How the game works

| | |
|---|---|
| **Bounty score** | Each guildie's mark adds 100. Each guildie they kill (a "gank") adds 100; repeat ganks on the same person in the same week count half each time. Everything halves every 14 days. Each claimed kill pays the bounty down by 50, so camping someone pays less and less unless they keep ganking. |
| **Bounty level** | Open-ended: Lv 1, 2, 3 and up. Bands: Dormant 0 · Suspect 1+ · Marked 4+ · Wanted 8+ · Most Wanted 14+ · Notorious 20+ · Public Enemy 28+ · Legendary 40+. A mark stops counting after about 8 weeks unless it's refreshed (re-marking, or being killed by them again). |
| **Kill value** | Killing blow pays **5 + 3 × level**. The level leaves out *your* mark and *your* deaths, so you can't farm your own alt or a friend. Points slide to 0 for targets 4–10 levels below you. **+50% each:** Top Bounty (#1 on the list) · revenge (they killed a guildie in the last hour) or rescue (a guildie called for help in the last 3 minutes) · first blood (your first kill of them this season). |
| **Assists** | Grouped guildies who hit the target in the last 20 seconds get half the base. |
| **On WoW: Forever** | Forever doesn't give addons the combat log, so: **kills** come from honour gains, and every guildie the game credits with the kill gets the full value (the bounty still drains once per kill). **Who killed you:** after you die, a small prompt lists up to three enemy players who were targeting you. Pick everyone who was in on it: each pick records a gank against them and marks them. **Help calls** go out when a KoS player (or anyone 5+ levels above you) is targeting you while you take damage. Grey kills give no honour, so they don't score. |
| **Calls for help** | Call by hand with `/kos sos` or a key binding (Key Bindings → AddOns → Utu). When a KoS player (or anyone 5+ levels above you) attacks you, guildies **within 400 yards in the same zone** get a banner with the distance and direction ("120 yd W") and an **On my way** button. You see who's coming. Kill the attacker within 3 minutes for +50% rescue. Responders who get there (within 150 yd when the attacker dies) earn an assist. The range is a setting: 200/400/800/1500 yd, whole zone, or anywhere. |
| **Defending** | When anyone 5+ levels above a guildie attacks them, the guildie calls for help. Kill the attacker within 3 minutes and you mark them and earn 10 points. |
| **Hunter ranks** | Season points give a level: Tracker I–V, Scout, Bounty Hunter, Manhunter, Avenger, Revenger, Executioner, Slayer, Warlord, Grim Reaper, then Legend N. |
| **Badges** | First Blood, Big Game Hunter, Jackpot, Avenger, Guardian, Wingman, Nemesis Slain, Guild Breaker. |
| **Seasons** | Automatic, every 8 weeks. The leaderboard starts fresh; claims stay as history, so nemesis, war ledger and last season's top 3 remain. The Hunters tab has a "This week" view. |
| **Enemy guilds** | Guild bounty = the sum of its members' bounties. The whole guild becomes KOS at guild Lv 30 **and** 10+ ganks on us. Unmarked members are worth a flat 2 points. You'll see a skull on them, but no banners unless you turn those on. Each guild has a war ledger (us vs them). |
| **Battlegrounds** | Don't count: no claims, ganks or help calls inside instances. |

## Staying out of your way

- **Alerts on arrival only.** You're alerted when a marked player shows up, not every minute they stay. Several arrivals at once become one "6 KoS nearby" banner.
- **Quiet thresholds.** Below bounty Lv 3 there's no alert, except for players *you* marked. Battlegrounds and arenas are quiet by default.
- **Activity tab.** Every guild event goes there. Chat shows only what's about you, near you, or big news, at most 4 lines per 10 seconds. You can change this in Settings.
- **Help calls.** One banner per attacker, only within range (400 yd by default), never for your own group, and at most one every 15 seconds.
- **Zone threat.** Entering a zone with KoS sightings or guildie deaths in the last 30 minutes shows one small toast: "Stranglethorn Vale: High threat - 3 KoS seen (Gankdude Lv 14...), 2 guildies ganked". It's silent when the zone is clear and won't repeat within 10 minutes unless things get worse. Useful even if you never PvP.
- **Tracker.** Hidden in raids and battlegrounds. Closing it snoozes it for 15 minutes.
- **Sync during combat.** Bulk sync waits until you're out of combat.
- **While you were away.** One summary line after you log in.

## Officers

The **Officer** tab sets guild rules. They're saved in the guild info text, so every member's addon uses the same ones:
- who can pardon, who can mark
- the whole-guild KOS level
- bounty half-life
- season length

The tab can also start the next season early. Its **claims review** flags `farm?` and `inflated?` claims and lets you strike them for everyone, and **Check for brigading** lists players with 5+ marks but no ganks.

## Limitations

- Claims are self-reported; there's no server to check them against. Officer review is the backstop.
- Detection needs nameplates, the combat log, target or mouseover. Addons can't scan for players.
- Guild names can only be read from visible players.
- Healers don't land killing blows, so they mostly score through assists (on Forever, honour credit pays them too).
- Forever hides some information from addons. `/kos probe` (best with an enemy player targeted) tests what your client allows and saves the results; the Settings tab shows a summary at the top right.
- Marks not reaching a guildie? `/utu sync` shows what was sent and received this session and which guildies (and versions) you've heard from, then asks everyone online to compare lists. Both of you need to be online, and versions before 0.5.0 can't receive names with spaces.
- Forever names can have spaces. Type them as they are in the window, or use quotes in slash commands: `/kos add "Kind Eyes" camps the flight path`.
