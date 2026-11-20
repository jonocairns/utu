# Changelog

Newest first. Each `## version` section becomes that version's GitHub release notes
(which WowUp shows as the changelog) and the "What's new" message in game, so keep
bullets short and written for players. `./build.sh` checks that the top section
matches the version in `Utu/Utu.toc`.

## 0.10.1
- **Review attackers:** the death prompt starts folded with quick **Skip** and **Mark** actions. Open **Review** to choose who to mark or hate, or add one optional note for your guild. You have five seconds to undo before your choices apply.
- **Nearby players:** if the death recap does not show who damaged you, Utu offers private Hate and individual manual marks. These choices leave the guild's death reports alone.

## 0.10.0
- **Bounty claims:** Utu skips honour awards that don’t name the defeated player. Seeing a player die nearby isn’t enough to award bounty points.
- **Grudges:** Utu now remembers who killed you. When they turn up, the warning says how often ("killed you 3x"), and someone who killed you 3 or more times in a row, minutes apart, shows as **camped you**. Your own note shows before guildies' notes.
- **Hate them:** for a player who went over the line, confirm their name on the death prompt, then click the separate **Hate (private)** button under their name. Or right-click them, or type `/utu hate Name`. Hated players get a red warning and a screen flash, warn again each time they come back, and stay flagged even after they drop off the list. Only you see it, and bounties and points don't change.
- **Grudge list:** `/utu grudges` lists everyone who has killed you, hated players first.
- **Death prompt:** now also offers a player who helped a mob kill you, or who was targeting you up to 30 seconds before you died. If Utu has no recap or recent targeting information, it lists nearby enemies. Utu waits for your confirmation before counting a suspected attacker in your grudge history. If it saw nobody at all, `/utu grudges` says so.

## 0.9.0
- **Map pins:** open the world map to see guildies' help calls (blue square) and where marked players were just spotted (skull). Hover a pin for who and how long ago. They fade over a few minutes and go when the player is killed. Turn them off with `/utu set mapPins off`.
- Sightings only get a pin when the guildie who spotted them is on 0.9.0, so get everyone to update.
- Needs a full game restart (not just `/reload`) to load.

## 0.8.1
- Fixed marking and syncing erroring after a `/reload` straight onto 0.8.0. Restart the game once (not just `/reload`) to switch signing on.

## 0.8.0
- **Signed marks and claims:** your marks, removals and claims now carry a signature only your computer can make. If a game crash loses them from your saved data, they come back from guildies without a false "Possible forgery" warning, and a forger still can't fake one.

## 0.7.9
- **Two-word names fixed:** Utu knew players with a two-word name (like "Yeh Neh") by their first word only. Their own help calls popped up for them, and their marks, removals, claims and pardons only reached guildies at the next full sync. Existing marks, claims and mutes move to the whole name when you log in.
- **Everyone should update:** older versions count an updated guildie's marks and claims twice until they do.

## 0.7.8
- **Forgery check:** if a sync brings in a mark, mark removal or bounty claim in your name that you never made, Utu warns you ("Possible forgery"), names the guildie whose sync relayed it, and lists it in `/utu sync`. Re-add a removed mark with `/utu add`; tell an officer about claims.

## 0.7.7
- **Harder to abuse:** Utu now ignores synced marks and claims dated in the future, and names can't carry colours, icons or links into other players' chat.
- A damaged saved list no longer stops Utu loading; the broken entries are dropped.
- Faster recounts for guilds with a long gank history, and a few rare errors fixed.

## 0.7.6
- Guildies hear about a marked player again when they turn up after a few minutes away, even though you only get one warning per zone.
- Seeing a marked player while resting or in a battleground no longer uses up your warning for that zone.
- Fixed zone changes sometimes being missed, which could skip or repeat a warning.

## 0.7.5
- **One alert per zone:** each marked player now warns you once per zone visit, instead of again every time they wander back into view. Leave the zone and come back for a fresh warning.
- Marking the player you're targeting no longer warns you about them straight after.
- Removed the "Alert again once gone for" setting.

## 0.7.4
- **What's new in game:** the first time you log in after Utu updates, chat lists what changed since your last version. `/utu news` shows it again.

## 0.7.3
- **Mute from the UI:** right-click a guildie's name and pick **Mute their marks**, or use the **Muted** button at the top of the Activity tab to see who you've muted, unmute them, or mute someone by name.
- Fixed the muted list running off the bottom of the Settings page (it now lives in the Activity tab).

## 0.7.2
- **Mute a guildie** whose marks you don't care about: click **Mute...** under a player's marks, or `/utu mute Name`. Players only they marked stop alerting you, and their marks and sightings are hidden from your Activity and chat. Just for you: bounties and points don't change, and their help calls and gank reports still show.

## 0.7.1
- **New logo:** a pūkana face, in the addon list, the addons dropdown, the minimap button and the window title. The raid skull still marks kill-on-sight players. Needs a full game restart (not just /reload) to load.

## 0.7.0
- **Minimap button** now uses the standard LibDBIcon library, so minimap button collectors (EllesmereUI, OneForAll and others) handle it properly, and it remembers where you drag it.
- **Sync** shares the game's addon-message limit with your other addons, so big list syncs don't slow down their messages.
- **Help banners** say "is under attack, likely by..." when the attacker is a guess, and "needs help against..." for manual calls, instead of always "is being ganked by".

## 0.6.9
- **Activity tab fixed:** it shows every mark, gank, claim, pardon and season in your guild list, including ones from while you were offline, plus sightings and help calls.
- The footer's "Syncing with guildies (N left)" count updates as it goes.

## 0.6.8
- Typed names get capitals like the game uses: "kind eyes" shows as "Kind Eyes". Existing names are fixed when you log in.

## 0.6.7
- Text no longer spills out of its space: long names truncate, the window title and footer stop before the buttons, pop-ups keep to two lines, and the help banner's lines never overlap its buttons.

## 0.6.6
- The "Worth N points to you" line no longer runs off the edge of the detail panel.

## 0.6.5
- **Two-word names fixed:** players marked by clicking them were saved as "Pi-Target" instead of "Pi Target". Existing marks, ganks and claims are repaired when you log in, merging duplicates. Everyone should update.

## 0.6.4
- **Update notice:** when a guildie running a newer Utu is online, you get one chat line telling you to update in WowUp.

## 0.6.3
- `/utu sync` shows what sync sent and received this session and which guildies (and versions) you've heard from.
- Hovering over players in combat no longer triggers a blocked-action error.
- The minimap button works inside UI packs that collect minimap buttons.

## 0.6.0
- First public release of **Utu**, a guild-run kill-on-sight list and bounty game for open-world PvP on WoW: Forever. *Utu* is te reo Māori for reciprocity: restoring balance after a wrong.
