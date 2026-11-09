-- Generated from CHANGELOG.md by build.sh; edit that instead.
local _, ns = ...
ns.KOS.CHANGES = {
    { "0.8.0", {
        "|cffffd100Signed marks and claims:|r your marks, removals and claims now carry a signature only your computer can make. If a game crash loses them from your saved data, they come back from guildies without a false \"Possible forgery\" warning, and a forger still can't fake one.",
    } },
    { "0.7.9", {
        "|cffffd100Two-word names fixed:|r Utu knew players with a two-word name (like \"Yeh Neh\") by their first word only. Their own help calls popped up for them, and their marks, removals, claims and pardons only reached guildies at the next full sync. Existing marks, claims and mutes move to the whole name when you log in.",
        "|cffffd100Everyone should update:|r older versions count an updated guildie's marks and claims twice until they do.",
    } },
    { "0.7.8", {
        "|cffffd100Forgery check:|r if a sync brings in a mark, mark removal or bounty claim in your name that you never made, Utu warns you (\"Possible forgery\"), names the guildie whose sync relayed it, and lists it in /utu sync. Re-add a removed mark with /utu add; tell an officer about claims.",
    } },
    { "0.7.7", {
        "|cffffd100Harder to abuse:|r Utu now ignores synced marks and claims dated in the future, and names can't carry colours, icons or links into other players' chat.",
        "A damaged saved list no longer stops Utu loading; the broken entries are dropped.",
        "Faster recounts for guilds with a long gank history, and a few rare errors fixed.",
    } },
    { "0.7.6", {
        "Guildies hear about a marked player again when they turn up after a few minutes away, even though you only get one warning per zone.",
        "Seeing a marked player while resting or in a battleground no longer uses up your warning for that zone.",
        "Fixed zone changes sometimes being missed, which could skip or repeat a warning.",
    } },
    { "0.7.5", {
        "|cffffd100One alert per zone:|r each marked player now warns you once per zone visit, instead of again every time they wander back into view. Leave the zone and come back for a fresh warning.",
        "Marking the player you're targeting no longer warns you about them straight after.",
        "Removed the \"Alert again once gone for\" setting.",
    } },
    { "0.7.4", {
        "|cffffd100What's new in game:|r the first time you log in after Utu updates, chat lists what changed since your last version. /utu news shows it again.",
    } },
    { "0.7.3", {
        "|cffffd100Mute from the UI:|r right-click a guildie's name and pick |cffffd100Mute their marks|r, or use the |cffffd100Muted|r button at the top of the Activity tab to see who you've muted, unmute them, or mute someone by name.",
        "Fixed the muted list running off the bottom of the Settings page (it now lives in the Activity tab).",
    } },
    { "0.7.2", {
        "|cffffd100Mute a guildie|r whose marks you don't care about: click |cffffd100Mute...|r under a player's marks, or /utu mute Name. Players only they marked stop alerting you, and their marks and sightings are hidden from your Activity and chat. Just for you: bounties and points don't change, and their help calls and gank reports still show.",
    } },
    { "0.7.1", {
        "|cffffd100New logo:|r a pūkana face, in the addon list, the addons dropdown, the minimap button and the window title. The raid skull still marks kill-on-sight players. Needs a full game restart (not just /reload) to load.",
    } },
    { "0.7.0", {
        "|cffffd100Minimap button|r now uses the standard LibDBIcon library, so minimap button collectors (EllesmereUI, OneForAll and others) handle it properly, and it remembers where you drag it.",
        "|cffffd100Sync|r shares the game's addon-message limit with your other addons, so big list syncs don't slow down their messages.",
        "|cffffd100Help banners|r say \"is under attack, likely by...\" when the attacker is a guess, and \"needs help against...\" for manual calls, instead of always \"is being ganked by\".",
    } },
    { "0.6.9", {
        "|cffffd100Activity tab fixed:|r it shows every mark, gank, claim, pardon and season in your guild list, including ones from while you were offline, plus sightings and help calls.",
        "The footer's \"Syncing with guildies (N left)\" count updates as it goes.",
    } },
    { "0.6.8", {
        "Typed names get capitals like the game uses: \"kind eyes\" shows as \"Kind Eyes\". Existing names are fixed when you log in.",
    } },
    { "0.6.7", {
        "Text no longer spills out of its space: long names truncate, the window title and footer stop before the buttons, pop-ups keep to two lines, and the help banner's lines never overlap its buttons.",
    } },
    { "0.6.6", {
        "The \"Worth N points to you\" line no longer runs off the edge of the detail panel.",
    } },
    { "0.6.5", {
        "|cffffd100Two-word names fixed:|r players marked by clicking them were saved as \"Pi-Target\" instead of \"Pi Target\". Existing marks, ganks and claims are repaired when you log in, merging duplicates. Everyone should update.",
    } },
    { "0.6.4", {
        "|cffffd100Update notice:|r when a guildie running a newer Utu is online, you get one chat line telling you to update in WowUp.",
    } },
    { "0.6.3", {
        "/utu sync shows what sync sent and received this session and which guildies (and versions) you've heard from.",
        "Hovering over players in combat no longer triggers a blocked-action error.",
        "The minimap button works inside UI packs that collect minimap buttons.",
    } },
    { "0.6.0", {
        "First public release of |cffffd100Utu|r, a guild-run kill-on-sight list and bounty game for open-world PvP on WoW: Forever. Utu is te reo Māori for reciprocity: restoring balance after a wrong.",
    } },
}
