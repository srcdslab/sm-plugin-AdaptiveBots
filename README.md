# AdaptiveBots

SourceMod plugin for Counter-Strike: Source that makes bots adapt to the level of the humans, without
them noticing: a beginner is not crushed, a good player is still challenged.

Made for the NiDE GunGame server (team deathmatch GunGame, `bot_quota 12` in `fill` mode, usually 0
to 4 humans against bots), but it works on any CS:S server with bots. Pure SourcePawn, no gamedata,
64-bit servers included. It needs SDKHooks and clientprefs, both shipped with SourceMod.

It has two levers:

- **Damage (per human, live)**: the damage bots deal to a human is scaled by that human's rating.
- **bot_difficulty (per map)**: at each map start, `bot_difficulty` is chosen from the average
  rating of the humans who played the previous map.

Nothing is shown to players: no chat, no hint, no menu.

## Rating

Each human has a rating against bots: a K/D ratio with a prior and a moving average.

- Only kills and deaths between a human and a bot count. Human vs human, suicides, world and fall
  deaths, and bot vs bot kills are ignored.
- On every such kill or death, the previous kills `K` and deaths `D` of the player are multiplied by
  `1 - sm_adaptivebots_smoothing`, then the kill (or the death) is added. With the default `0.05`,
  the rating follows about the last 20 engagements.
- `rating = (K + P) / (D + P)`, with `P = sm_adaptivebots_prior` (default `4`). A new player has
  `K = D = 0`, so he starts at `1.0` (average). The prior also keeps pulling every rating a little
  toward `1.0`, so a lucky streak does not swing it too far.

Steady state with the defaults (a player who keeps the same K/D against bots):

| K/D against bots | 0.25 | 0.5 | 1 | 2 | 3 | 4 |
| - | - | - | - | - | - | - |
| Rating | 0.40 | 0.62 | 1.00 | 1.62 | 2.11 | 2.50 |

The rating is stored in the `adaptivebots_rating` cookie (`kills;deaths;time of the last update`),
so a returning player starts at his rating. After a long absence, part of the evidence is
forgotten: `K` and `D` are multiplied by `0.5 ^ (days away / sm_adaptivebots_decay_days)` when the
cookie loads (default 14 days, `0` = never), so the rating drifts back toward `1.0`. Until the
cookies of a player are loaded, his kills and deaths are not counted and he plays at `1.0`.

The rating measures the player against the bots as they are, damage scaling included. The damage
lever is therefore a proportional correction: a weak player takes less damage, wins more
engagements, his rating rises and the correction shrinks. He ends up between his unassisted level
and the average, not exactly at the average. This is on purpose: the bots get easier for him, they
do not hide the difference.

## Damage scaling

The rating is mapped to a multiplier of the damage bots deal to that human, smoothly and
symmetrically in log space (a rating of 2.0 is as far above average as 0.5 is below):

```
u = tanh( ln(rating) / ln(sm_adaptivebots_rating_scale) )      -1 < u < 1
multiplier = 1 + (damage_max - 1) * u      when u >= 0
multiplier = 1 + (1 - damage_min) * u      when u < 0
```

The multiplier is exactly `1.0` at a rating of `1.0`, never leaves `[damage_min, damage_max]`, and
covers 76% of the way to the bound (tanh 1) at `rating_scale` (default `2.0`) or its inverse.

With the defaults (`damage_min 0.6`, `damage_max 1.25`, `rating_scale 2.0`):

| Rating | 0.33 | 0.5 | 0.7 | 0.85 | 1.0 | 1.2 | 1.5 | 2.0 | 3.0 |
| - | - | - | - | - | - | - | - | - | - |
| Bot damage multiplier | 0.63 | 0.70 | 0.81 | 0.91 | 1.00 | 1.06 | 1.13 | 1.19 | 1.23 |
| Damage to bots, `reverse_max 0.25` | 1.23 | 1.19 | 1.12 | 1.06 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

The scaling runs in `SDKHook_OnTakeDamage` on humans, only when the attacker is a bot on the other
team. Human vs human, world, `trigger_hurt`, fall damage and bot vs bot damage are never changed.
Grenades count as damage from their thrower.

**Reverse lever** (off by default): with `sm_adaptivebots_reverse_max` above 0, weak humans also deal
more damage to bots, `1 + reverse_max * (1 - multiplier) / (1 - damage_min)`: up to
`+reverse_max` for the weakest players, nothing for average and strong ones.

## bot_difficulty

### How CS:S picks bots

From the game code (`cs_bot_manager.cpp`, `bot_profile.cpp`):

- `bot_difficulty` is read when a bot is added: `BotAddCommand` takes a random free profile of
  `BotProfile.db` whose `Difficulty` includes the current level. Bots already in game keep their
  profile, so a change only applies to bots added afterwards.
- A profile's `Difficulty` comes from `Default`, then from its templates in order (a template only
  overrides it when its value differs from `Default`), then from its own `Difficulty =` line.
  `NORMAL+HARD` profiles can be picked at both levels.
- The skill of a bot (`Skill`, `ReactionTime`, `AttackDelay`, `Aggression`) comes from its profile,
  so the difficulty level works by choosing among different profiles, and names.
- If no free profile matches, the quota bot is not added at all: there is no fallback name.
- Bots are removed at every map change and the quota adds them again, one per server frame, from
  the first frames of the new map. In `fill` and `match` mode the quota stops adding bots once the
  round is 20 seconds old.
- The game reads the bot profile databases again at each map start (`BotPackList.db` if it exists,
  else `BotProfile.db`, through the game file system, so `custom/*/botprofile.db` wins over the VPK).

On the NiDE GunGame server, `custom/nide_gg/botprofile.db` (140 profiles with player-like names) has
`Elite`/`Expert` (EXPERT), `VeryHard`/`Hard` (HARD), `Tough` (NORMAL+HARD), `Normal` (NORMAL),
`Fair` (EASY+NORMAL) and `Easy` (EASY) templates. Every name belongs to one or two levels, and each
level has enough names for `bot_quota 12`:

| Level | EASY (0) | NORMAL (1) | HARD (2) | EXPERT (3) |
| - | - | - | - | - |
| Profiles | 59 | 65 | 38 | 21 |

Changing `bot_difficulty` changes which names show up, but the names keep working: bots get new
random names at each map change anyway. The plugin reads the database itself at map start and logs
a warning when a level has fewer profiles than `bot_quota`.

### What the plugin does

1. Every 5 seconds it saves the average (geometric mean) rating of the humans on a team. At
   `OnMapEnd` it chooses the level of the next map from it, and sets `bot_difficulty` right away,
   so the bots added in the first frames of the next map already use it.
2. In `OnConfigsExecuted` (after `server.cfg` and the plugin configs) it sets `bot_difficulty`
   again. From then on, a change hook sets `bot_difficulty` back whenever something else changes it
   during the map (a map config, `gungame.mapconfig.cfg`, an admin).
3. Once the bot count has stopped changing (checked every second after the configs), it looks up
   each bot's name in the profile database. Bots whose profile does not include the chosen level
   are kicked once, and the quota adds matching ones. This only happens at map start, at most once
   per map, only for bots that do not match (usually none: step 1 already took care of them), and
   only while the round is less than 15 seconds old, so the quota refills the slots; humans are
   usually still loading the map. It is skipped if the level has fewer profiles than bots in game.

Level choice from the average rating `r` (`sm_adaptivebots_difficulty_*` thresholds):

| `r` | `< 0.7` | `0.7 - 1.5` | `1.5 - 2.2` | `>= 2.2` |
| - | - | - | - | - |
| `bot_difficulty` | 0 (easy) | 1 (normal) | 2 (hard) | 3 (expert) |

Ratings are measured against the bots of the current level, so harder bots lower them. To avoid
switching level at every map, the threshold must be passed by `sm_adaptivebots_difficulty_hysteresis`
(default 15%) to leave the current level: from normal, hard needs `r >= 1.725`; from hard, the
level only drops back to normal when `r < 1.275`.

With no human on a team at the end of the previous map (or on the first map after the plugin
loaded), the level is `sm_adaptivebots_difficulty_default` (1). Humans who join during a map do not
change the level of that map: the damage lever adapts to them right away, the level follows at the
next map.

### Config interaction

- `server.cfg` (`bot_difficulty 1` on NiDE GunGame) runs at every map start, before
  `OnConfigsExecuted`. It does not need to change: the plugin sets the level after it, and its
  change hook sets it back immediately if a config sets it again, so the value only stays in
  `server.cfg` as the fallback when the plugin is not loaded.
- `cfg/gungame/css/gungame.mapconfig.cfg` is executed by GunGame after the other configs. A
  `bot_difficulty` line there (none today) is overridden the same way.
- To set `bot_difficulty` by hand (tests, events), set `sm_adaptivebots_difficulty 0` first,
  otherwise the plugin sets it back. `sm_adaptivebots_enable 0` turns everything off.

## Commands

| Command | Access | Description |
| - | - | - |
| `sm_adaptivebots_status` | generic admin (`b`) | Prints, in the console, each human's rating, kills, deaths, bot damage multiplier and damage to bots multiplier, the current `bot_difficulty` and why it was chosen, the profiles per level and what happened to the bots at map start |
| `sm_adaptivebots_setrating <target> <rating>` | root (`z`) | Sets the rating of humans (`0.1` to `10`, `1.0` = average) as if they had played about `1 / smoothing` engagements at that level, for tests. The rating is saved in the cookie |

## Cvars

Written to `cfg/sourcemod/plugin.AdaptiveBots.cfg` on the first start.

| Cvar | Default | Description |
| - | - | - |
| `sm_adaptivebots_enable` | `1` | Enable adaptive bots (rating, damage scaling and bot_difficulty) |
| `sm_adaptivebots_damage_min` | `0.6` | Multiplier of bot damage on the weakest humans |
| `sm_adaptivebots_damage_max` | `1.25` | Multiplier of bot damage on the strongest humans |
| `sm_adaptivebots_rating_scale` | `2.0` | Rating (or its inverse) where the bot damage multiplier has covered 76% of the way to `damage_max` (or `damage_min`) |
| `sm_adaptivebots_smoothing` | `0.05` | Weight of the newest human vs bot kill or death in the rating (memory of about `1/x` engagements) |
| `sm_adaptivebots_prior` | `4` | Average engagements (half kills, half deaths) added to every rating, so new players start at 1.0 |
| `sm_adaptivebots_decay_days` | `14` | Days of absence after which half of a stored rating's evidence is forgotten, `0` = never |
| `sm_adaptivebots_reverse_max` | `0.0` | Extra damage the weakest humans deal to bots (`0.25` = up to +25%), `0` = off |
| `sm_adaptivebots_difficulty` | `1` | Choose `bot_difficulty` at each map start, `0` = leave `bot_difficulty` alone |
| `sm_adaptivebots_difficulty_default` | `1` | `bot_difficulty` used when no human played the previous map |
| `sm_adaptivebots_difficulty_easy` | `0.7` | Average rating below which bots are easy (0) |
| `sm_adaptivebots_difficulty_hard` | `1.5` | Average rating from which bots are hard (2) |
| `sm_adaptivebots_difficulty_expert` | `2.2` | Average rating from which bots are expert (3) |
| `sm_adaptivebots_difficulty_hysteresis` | `0.15` | Relative margin a threshold must be passed by before `bot_difficulty` changes |
| `sm_adaptivebots_readd` | `1` | At map start, kick the bots whose profile does not match the chosen level so the quota adds matching ones |
| `sm_adaptivebots_debug` | `0` | Log to the SourceMod logs: `1` = level choices and re-adds, `2` = also every rating update |

## Limits

- The level changes once per map. Mid-map, only the damage lever reacts to who is playing.
- The rating only sees kills and deaths, not damage or accuracy. In GunGame, the weapon of the
  current level weighs on it too.
- A damage display plugin (ShowDamageText) shows the real damage dealt: with the reverse lever on,
  a weak player sees higher numbers on bots. The bot damage lever itself shows nothing special.
- The re-add needs the bot names to be the profile names (`bot_prefix ""`, or a prefix followed by a
  space). Bots renamed by another plugin are left alone.
- If the server hibernates when empty, the game removes the bots; this plugin does not change that.
- Ratings follow the auth id used by clientprefs. On a `sv_nosteam` server, players whose emulator
  gives a shared or changing id share or lose their rating.

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/AdaptiveBots.smx`

## License

GPL-3.0, see [LICENSE](LICENSE).
