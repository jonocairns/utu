# Embedded libraries

Standard WoW addon libraries, copied unmodified from their upstream sources. Each keeps its own licence; Utu's MIT licence doesn't cover them.

| Library | Version | Source | Licence |
|---|---|---|---|
| LibStub | minor 2 | [Ace3](https://github.com/WoWUIDev/Ace3/tree/master/LibStub) | Public domain (see file header) |
| CallbackHandler-1.0 | minor 8 | [Ace3](https://github.com/WoWUIDev/Ace3/tree/master/CallbackHandler-1.0) | BSD-style, see `CallbackHandler-1.0/LICENSE.txt` |
| LibDataBroker-1.1 | 1.1 | [tekkub/libdatabroker-1-1](https://github.com/tekkub/libdatabroker-1-1) | As published by the author |
| LibDBIcon-1.0 | minor 57 | [wowace libdbicon-1-0](https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0) | As published by the author |
| ChatThrottleLib | v32 | [Ace3 (AceComm-3.0)](https://github.com/WoWUIDev/Ace3/tree/master/AceComm-3.0) | Public domain (see file header) |

To update one, replace its file with the upstream copy. Each library checks its version through LibStub (or `ChatThrottleLib.version`), so when several addons embed it, the newest copy wins.
