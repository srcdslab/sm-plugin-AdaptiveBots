#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#define PLUGIN_VERSION "1.0.0"

#define DIFFICULTY_LEVELS 4
#define DIFFICULTY_NONE -1

// Same order and spelling as BotDifficultyName[] in the game (shared/cstrike/bot/bot_constants.h):
// bot_difficulty 0..3 and the "Difficulty = A+B" keywords of BotProfile.db
static const char g_sDifficultyNames[DIFFICULTY_LEVELS][] = { "EASY", "NORMAL", "HARD", "EXPERT" };

// Bots kicked at map start come back through the bot quota. In "fill" and "match" mode,
// CCSBotManager::MaintainBotQuota (server/cstrike/bot/cs_bot_manager.cpp) stops adding bots once
// the round is 20 s old (isRoundInProgress), so bots are only kicked while the round is younger
// than this, with a margin.
#define READD_MAX_ROUND_TIME 15.0
// The bot count is checked every second after the configs ran; bots are re-added once it stopped
// changing (the quota adds one bot per server frame), or after this many checks.
#define READD_CHECK_INTERVAL 1.0
#define READD_MAX_CHECKS 20
// Reason shown in the disconnect line of a re-added bot: the same as an ordinary leave
#define READD_KICK_REASON "Disconnect by user."

// How often the average rating of the humans in game is saved for the next map. It is not
// computed in OnMapEnd alone: clients may already be disconnected when it runs.
#define SNAPSHOT_INTERVAL 5.0

#define SECONDS_PER_DAY 86400.0

// Bot rating handed to setrating is kept within these bounds
#define RATING_MIN 0.1
#define RATING_MAX 10.0

ConVar g_cvEnable;
ConVar g_cvDamageMin;
ConVar g_cvDamageMax;
ConVar g_cvRatingScale;
ConVar g_cvSmoothing;
ConVar g_cvPrior;
ConVar g_cvDecayDays;
ConVar g_cvReverseMax;
ConVar g_cvDifficulty;
ConVar g_cvDifficultyDefault;
ConVar g_cvThresholdEasy;
ConVar g_cvThresholdHard;
ConVar g_cvThresholdExpert;
ConVar g_cvHysteresis;
ConVar g_cvReadd;
ConVar g_cvDebug;

ConVar g_cvBotDifficulty;
ConVar g_cvBotQuota;

Cookie g_cRating;

// Exponentially weighted kills and deaths of each human against bots
float g_fKills[MAXPLAYERS + 1];
float g_fDeaths[MAXPLAYERS + 1];
bool g_bRatingLoaded[MAXPLAYERS + 1];

// bot_difficulty chosen for the current map, and why
int g_iDifficulty = DIFFICULTY_NONE;
char g_sDifficultyReason[256];
// True when OnMapEnd already chose the difficulty of the next map
bool g_bChosenAtMapEnd;
// Set while this plugin writes bot_difficulty, so its change hook lets the value through
bool g_bSettingDifficulty;

// Last average rating of the humans on a team, refreshed every SNAPSHOT_INTERVAL seconds
float g_fSnapshotRating = 1.0;
int g_iSnapshotHumans;
Handle g_hSnapshotTimer;

// Bot profile name -> difficulty bit flags (1 << level), read from the bot profile databases
StringMap g_smProfiles;
int g_iPoolSize[DIFFICULTY_LEVELS];
bool g_bProfilesLoaded;

Handle g_hReaddTimer;
int g_iReaddChecks;
int g_iReaddLastBots;
char g_sReaddState[192];

public Plugin myinfo =
{
	name = "AdaptiveBots",
	author = "Rushaway",
	description = "Bots adapt to the level of the humans: per-player damage scaling and bot_difficulty per map",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-AdaptiveBots"
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_adaptivebots_enable", "1", "Enable adaptive bots (rating, damage scaling and bot_difficulty)", _, true, 0.0, true, 1.0);
	g_cvDamageMin = CreateConVar("sm_adaptivebots_damage_min", "0.6", "Multiplier of bot damage on the weakest humans", _, true, 0.1, true, 1.0);
	g_cvDamageMax = CreateConVar("sm_adaptivebots_damage_max", "1.25", "Multiplier of bot damage on the strongest humans", _, true, 1.0, true, 3.0);
	g_cvRatingScale = CreateConVar("sm_adaptivebots_rating_scale", "2.0", "Rating (or its inverse) where the bot damage multiplier has covered 76% of the way to damage_max (or damage_min)", _, true, 1.1, true, 10.0);
	g_cvSmoothing = CreateConVar("sm_adaptivebots_smoothing", "0.05", "Weight of the newest human vs bot kill or death in the rating (memory of about 1/x engagements)", _, true, 0.005, true, 0.5);
	g_cvPrior = CreateConVar("sm_adaptivebots_prior", "4", "Average engagements (half kills, half deaths) added to every rating, so new players start at 1.0", _, true, 0.5, true, 100.0);
	g_cvDecayDays = CreateConVar("sm_adaptivebots_decay_days", "14", "Days of absence after which half of a stored rating's evidence is forgotten (it drifts back to 1.0), 0 = never", _, true, 0.0, true, 3650.0);
	g_cvReverseMax = CreateConVar("sm_adaptivebots_reverse_max", "0.0", "Extra damage the weakest humans deal to bots (0.25 = up to +25%), 0 = off", _, true, 0.0, true, 1.0);
	g_cvDifficulty = CreateConVar("sm_adaptivebots_difficulty", "1", "Choose bot_difficulty at each map start from the ratings of the humans, 0 = leave bot_difficulty alone", _, true, 0.0, true, 1.0);
	g_cvDifficultyDefault = CreateConVar("sm_adaptivebots_difficulty_default", "1", "bot_difficulty used when no human played the previous map", _, true, 0.0, true, 3.0);
	g_cvThresholdEasy = CreateConVar("sm_adaptivebots_difficulty_easy", "0.7", "Average rating below which bots are easy (bot_difficulty 0)", _, true, 0.1, true, 10.0);
	g_cvThresholdHard = CreateConVar("sm_adaptivebots_difficulty_hard", "1.5", "Average rating from which bots are hard (bot_difficulty 2)", _, true, 0.1, true, 10.0);
	g_cvThresholdExpert = CreateConVar("sm_adaptivebots_difficulty_expert", "2.2", "Average rating from which bots are expert (bot_difficulty 3)", _, true, 0.1, true, 10.0);
	g_cvHysteresis = CreateConVar("sm_adaptivebots_difficulty_hysteresis", "0.15", "Relative margin the average rating must pass a threshold by before bot_difficulty changes (0.15 = 15%)", _, true, 0.0, true, 0.9);
	g_cvReadd = CreateConVar("sm_adaptivebots_readd", "1", "At map start, kick the bots whose profile does not match the chosen bot_difficulty so the bot quota adds matching ones", _, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("sm_adaptivebots_debug", "0", "Log to the SourceMod logs: 1 = bot_difficulty choices and re-adds, 2 = also every rating update", _, true, 0.0, true, 2.0);

	AutoExecConfig(true);

	g_cvBotDifficulty = FindConVar("bot_difficulty");
	g_cvBotQuota = FindConVar("bot_quota");
	if (g_cvBotDifficulty == null || g_cvBotQuota == null)
		SetFailState("bot_difficulty or bot_quota not found: this plugin needs the Counter-Strike: Source bots");

	g_cvBotDifficulty.AddChangeHook(OnBotDifficultyChanged);
	g_cvEnable.AddChangeHook(OnLeverChanged);
	g_cvDifficulty.AddChangeHook(OnLeverChanged);

	g_cRating = new Cookie("adaptivebots_rating", "AdaptiveBots skill rating against bots (kills;deaths;last update)", CookieAccess_Private);

	HookEvent("player_death", Event_PlayerDeath);

	RegAdminCmd("sm_adaptivebots_status", Command_Status, ADMFLAG_GENERIC, "Show the rating and bot damage multiplier of each human and the current bot_difficulty");
	RegAdminCmd("sm_adaptivebots_setrating", Command_SetRating, ADMFLAG_ROOT, "sm_adaptivebots_setrating <target> <rating> - Set the rating of humans (1.0 = average), for tests");

	LoadTranslations("common.phrases");

	strcopy(g_sReaddState, sizeof(g_sReaddState), "not checked yet");

	// Late load
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;

		OnClientPutInServer(client);
		if (!IsFakeClient(client) && AreClientCookiesCached(client))
			OnClientCookiesCached(client);
	}
}

public void OnMapStart()
{
	// The game reads the bot profile databases again at each map start (CCSBotManager::ServerActivate)
	LoadBotProfiles();

	strcopy(g_sReaddState, sizeof(g_sReaddState), "not checked yet");

	if (g_hSnapshotTimer == null)
		g_hSnapshotTimer = CreateTimer(SNAPSHOT_INTERVAL, Timer_Snapshot, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	// Both timers carry TIMER_FLAG_NO_MAPCHANGE: the map change closes them
	g_hSnapshotTimer = null;
	g_hReaddTimer = null;

	if (!IsDifficultyLeverOn())
		return;

	// Humans may still be in game here; if they are already gone, the last snapshot (at most
	// SNAPSHOT_INTERVAL seconds old) stands for them
	float fRating;
	int iHumans = GetGroupRating(fRating);
	if (iHumans > 0)
	{
		g_fSnapshotRating = fRating;
		g_iSnapshotHumans = iHumans;
	}

	ChooseDifficulty(g_fSnapshotRating, g_iSnapshotHumans, "at the end of the previous map");
	g_bChosenAtMapEnd = true;

	// Set now, so the bots the quota adds in the first frames of the next map already use it
	ApplyDifficulty();
}

public void OnConfigsExecuted()
{
	if (!IsDifficultyLeverOn())
	{
		g_bChosenAtMapEnd = false;
		return;
	}

	if (!g_bChosenAtMapEnd)
	{
		// First map since the plugin loaded: only humans already in game (late load) can count
		float fRating;
		int iHumans = GetGroupRating(fRating);
		ChooseDifficulty(fRating, iHumans, "in game when the plugin started");
	}
	g_bChosenAtMapEnd = false;

	// server.cfg (bot_difficulty 1 on NiDE GunGame) and the plugin configs have run by now. The
	// change hook also sets bot_difficulty back if a later config (gungame.mapconfig.cfg) changes it.
	ApplyDifficulty();

	if (g_cvDebug.IntValue >= 1)
		LogMessage("bot_difficulty %d (%s): %s", g_iDifficulty, g_sDifficultyNames[g_iDifficulty], g_sDifficultyReason);

	StartReaddCheck();
}

public void OnClientConnected(int client)
{
	ResetRating(client);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientCookiesCached(int client)
{
	if (IsFakeClient(client))
		return;

	char sValue[64];
	g_cRating.Get(client, sValue, sizeof(sValue));

	float fKills, fDeaths;
	int iTime;
	if (ParseRating(sValue, fKills, fDeaths, iTime))
	{
		// Forget part of the evidence after a long absence: the rating drifts back to the prior
		float fHalfLife = g_cvDecayDays.FloatValue;
		float fDays = float(GetTime() - iTime) / SECONDS_PER_DAY;
		if (fHalfLife > 0.0 && fDays > 0.0)
		{
			float fKeep = Pow(0.5, fDays / fHalfLife);
			fKills *= fKeep;
			fDeaths *= fKeep;
		}

		g_fKills[client] = fKills;
		g_fDeaths[client] = fDeaths;
	}

	g_bRatingLoaded[client] = true;
}

public void OnClientDisconnect(int client)
{
	if (g_bRatingLoaded[client] && !IsFakeClient(client))
		SaveRating(client);

	ResetRating(client);
}

// ---------------------------------------------------------------------------------------------
// Rating
// ---------------------------------------------------------------------------------------------

void ResetRating(int client)
{
	g_fKills[client] = 0.0;
	g_fDeaths[client] = 0.0;
	g_bRatingLoaded[client] = false;
}

bool ParseRating(const char[] sValue, float &fKills, float &fDeaths, int &iTime)
{
	if (sValue[0] == '\0')
		return false;

	char sParts[3][24];
	if (ExplodeString(sValue, ";", sParts, sizeof(sParts), sizeof(sParts[])) != 3)
		return false;

	fKills = StringToFloat(sParts[0]);
	fDeaths = StringToFloat(sParts[1]);
	iTime = StringToInt(sParts[2]);

	if (fKills < 0.0 || fDeaths < 0.0)
		return false;

	return true;
}

void SaveRating(int client)
{
	char sValue[64];
	FormatEx(sValue, sizeof(sValue), "%.4f;%.4f;%d", g_fKills[client], g_fDeaths[client], GetTime());
	g_cRating.Set(client, sValue);
}

// (kills + prior) / (deaths + prior): a K/D ratio against bots pulled toward 1.0 by the prior
float GetRating(int client)
{
	float fPrior = g_cvPrior.FloatValue;
	return (g_fKills[client] + fPrior) / (g_fDeaths[client] + fPrior);
}

// One kill or death of a human against a bot: older engagements fade by (1 - smoothing)
void AddEngagement(int client, bool bWon)
{
	if (!g_bRatingLoaded[client])
		return;

	float fKeep = 1.0 - g_cvSmoothing.FloatValue;
	g_fKills[client] *= fKeep;
	g_fDeaths[client] *= fKeep;

	if (bWon)
		g_fKills[client] += 1.0;
	else
		g_fDeaths[client] += 1.0;

	SaveRating(client);

	if (g_cvDebug.IntValue >= 2)
		LogMessage("%L %s a bot: rating %.2f, bot damage x%.2f", client, bWon ? "killed" : "was killed by", GetRating(client), GetDamageMultiplier(client));
}

// Sets kills and deaths so that the rating equals fRating, with the evidence of a player who
// has played long enough to fill the moving average (1 / smoothing engagements)
void SetRating(int client, float fRating)
{
	float fPrior = g_cvPrior.FloatValue;
	float fTotal = 1.0 / g_cvSmoothing.FloatValue;

	// K + D = total and (K + P) / (D + P) = rating
	float fDeaths = (fTotal + fPrior * (1.0 - fRating)) / (1.0 + fRating);
	float fKills = fTotal - fDeaths;
	if (fDeaths < 0.0)
	{
		fDeaths = 0.0;
		fKills = fPrior * (fRating - 1.0);
	}
	else if (fKills < 0.0)
	{
		fKills = 0.0;
		fDeaths = fPrior * (1.0 - fRating) / fRating;
	}

	g_fKills[client] = fKills;
	g_fDeaths[client] = fDeaths;

	if (AreClientCookiesCached(client))
	{
		g_bRatingLoaded[client] = true;
		SaveRating(client);
	}
}

// Maps a rating to -1..1: 0 at 1.0, +-0.76 (tanh 1) at rating_scale or its inverse, smooth and
// symmetric in log space (a rating of 2.0 is as far above average as 0.5 is below)
float RatingToUnit(float fRating)
{
	float fX = Logarithm(fRating) / Logarithm(g_cvRatingScale.FloatValue);
	if (fX > 10.0)
		fX = 10.0;
	else if (fX < -10.0)
		fX = -10.0;

	float fE = Exponential(2.0 * fX);
	return (fE - 1.0) / (fE + 1.0);
}

// Multiplier of the damage bots deal to this human
float GetDamageMultiplier(int client)
{
	float fUnit = RatingToUnit(GetRating(client));
	if (fUnit >= 0.0)
		return 1.0 + (g_cvDamageMax.FloatValue - 1.0) * fUnit;

	return 1.0 + (1.0 - g_cvDamageMin.FloatValue) * fUnit;
}

// Multiplier of the damage this human deals to bots: only weak humans get a boost, in proportion
// to how far their bot damage multiplier went toward damage_min
float GetReverseMultiplier(int client)
{
	float fReverseMax = g_cvReverseMax.FloatValue;
	float fMin = g_cvDamageMin.FloatValue;
	if (fReverseMax <= 0.0 || fMin >= 1.0)
		return 1.0;

	float fMultiplier = GetDamageMultiplier(client);
	if (fMultiplier >= 1.0)
		return 1.0;

	return 1.0 + fReverseMax * (1.0 - fMultiplier) / (1.0 - fMin);
}

// Geometric mean of the ratings of the humans on a team. Returns the number of humans.
int GetGroupRating(float &fRating)
{
	float fSum = 0.0;
	int iHumans = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) < 2)
			continue;

		fSum += Logarithm(GetRating(client));
		iHumans++;
	}

	if (iHumans == 0)
	{
		fRating = 1.0;
		return 0;
	}

	fRating = Pow(10.0, fSum / float(iHumans));
	return iHumans;
}

public Action Timer_Snapshot(Handle timer)
{
	g_iSnapshotHumans = GetGroupRating(g_fSnapshotRating);
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Kills, deaths and damage
// ---------------------------------------------------------------------------------------------

bool IsBot(int client)
{
	return IsFakeClient(client) && !IsClientSourceTV(client) && !IsClientReplay(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
		return;

	int iVictim = GetClientOfUserId(event.GetInt("userid"));
	int iAttacker = GetClientOfUserId(event.GetInt("attacker"));
	if (iVictim == 0 || iAttacker == 0 || iVictim == iAttacker)
		return;

	if (GetClientTeam(iVictim) == GetClientTeam(iAttacker))
		return;

	bool bVictimBot = IsBot(iVictim);
	bool bAttackerBot = IsBot(iAttacker);

	if (bAttackerBot && !IsFakeClient(iVictim))
		AddEngagement(iVictim, false);
	else if (bVictimBot && !IsFakeClient(iAttacker))
		AddEngagement(iAttacker, true);
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;

	// World, trigger_hurt and fall damage have no player attacker
	if (attacker < 1 || attacker > MaxClients || attacker == victim || !IsClientInGame(attacker))
		return Plugin_Continue;

	if (damagetype & DMG_FALL)
		return Plugin_Continue;

	if (GetClientTeam(attacker) == GetClientTeam(victim))
		return Plugin_Continue;

	float fScale;
	if (IsBot(attacker) && !IsFakeClient(victim))
		fScale = GetDamageMultiplier(victim);
	else if (IsBot(victim) && !IsFakeClient(attacker))
		fScale = GetReverseMultiplier(attacker);
	else
		return Plugin_Continue;

	if (fScale == 1.0)
		return Plugin_Continue;

	damage *= fScale;
	return Plugin_Changed;
}

// ---------------------------------------------------------------------------------------------
// bot_difficulty
// ---------------------------------------------------------------------------------------------

bool IsDifficultyLeverOn()
{
	return g_cvEnable.BoolValue && g_cvDifficulty.BoolValue;
}

float GetThreshold(int iLevel)
{
	switch (iLevel)
	{
		case 1: return g_cvThresholdEasy.FloatValue;
		case 2: return g_cvThresholdHard.FloatValue;
	}
	return g_cvThresholdExpert.FloatValue;
}

// Plain thresholds: rating < easy -> 0, < hard -> 1, < expert -> 2, else 3
int GetLevelForRating(float fRating)
{
	int iLevel = 0;
	while (iLevel < DIFFICULTY_LEVELS - 1 && fRating >= GetThreshold(iLevel + 1))
		iLevel++;

	return iLevel;
}

void ChooseDifficulty(float fRating, int iHumans, const char[] sWhen)
{
	int iPrevious = g_iDifficulty;

	if (iHumans == 0)
	{
		g_iDifficulty = g_cvDifficultyDefault.IntValue;
		FormatEx(g_sDifficultyReason, sizeof(g_sDifficultyReason), "no human on a team %s, default (sm_adaptivebots_difficulty_default)", sWhen);
		return;
	}

	int iLevel = GetLevelForRating(fRating);

	// Hysteresis: from the previous level, a threshold must be passed by the margin. The ratings
	// are measured against the bots of the previous level, so without it a group close to a
	// threshold would switch level at every map.
	if (iPrevious != DIFFICULTY_NONE && iLevel != iPrevious)
	{
		float fMargin = g_cvHysteresis.FloatValue;
		iLevel = iPrevious;
		if (GetLevelForRating(fRating) > iPrevious)
		{
			while (iLevel < DIFFICULTY_LEVELS - 1 && fRating >= GetThreshold(iLevel + 1) * (1.0 + fMargin))
				iLevel++;
		}
		else
		{
			while (iLevel > 0 && fRating < GetThreshold(iLevel) * (1.0 - fMargin))
				iLevel--;
		}
	}

	g_iDifficulty = iLevel;

	char sPrevious[16];
	if (iPrevious == DIFFICULTY_NONE)
		strcopy(sPrevious, sizeof(sPrevious), "none");
	else
		strcopy(sPrevious, sizeof(sPrevious), g_sDifficultyNames[iPrevious]);

	FormatEx(g_sDifficultyReason, sizeof(g_sDifficultyReason), "average rating %.2f of %d human(s) %s; thresholds %.2f/%.2f/%.2f, hysteresis %.0f%%, previous level %s",
		fRating, iHumans, sWhen, g_cvThresholdEasy.FloatValue, g_cvThresholdHard.FloatValue, g_cvThresholdExpert.FloatValue,
		g_cvHysteresis.FloatValue * 100.0, sPrevious);
}

void ApplyDifficulty()
{
	if (!IsDifficultyLeverOn() || g_iDifficulty == DIFFICULTY_NONE)
		return;

	if (g_cvBotDifficulty.IntValue == g_iDifficulty)
		return;

	g_bSettingDifficulty = true;
	g_cvBotDifficulty.IntValue = g_iDifficulty;
	g_bSettingDifficulty = false;
}

// Keeps bot_difficulty at the chosen level when a config sets it later (server.cfg, map configs,
// gungame.mapconfig.cfg). Set sm_adaptivebots_difficulty 0 to change bot_difficulty by hand.
public void OnBotDifficultyChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_bSettingDifficulty || !IsDifficultyLeverOn() || g_iDifficulty == DIFFICULTY_NONE)
		return;

	if (StringToInt(newValue) == g_iDifficulty)
		return;

	if (g_cvDebug.IntValue >= 1)
		LogMessage("bot_difficulty set to %s by something else, set back to %d", newValue, g_iDifficulty);

	g_bSettingDifficulty = true;
	convar.IntValue = g_iDifficulty;
	g_bSettingDifficulty = false;
}

public void OnLeverChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!IsDifficultyLeverOn())
		return;

	// Turned on in the middle of a map: choose from the humans in game, for the bots added from now on
	if (g_iDifficulty == DIFFICULTY_NONE)
	{
		float fRating;
		int iHumans = GetGroupRating(fRating);
		ChooseDifficulty(fRating, iHumans, "in game when the difficulty lever was turned on");
	}
	ApplyDifficulty();
}

// ---------------------------------------------------------------------------------------------
// Re-adding the bots at map start
// ---------------------------------------------------------------------------------------------

// bot_difficulty only applies to bots added after it changed: CCSBotManager::BotAddCommand picks
// a random free profile whose Difficulty includes the level (BotProfileManager::GetRandomProfile).
// Bots that joined with another level (before the configs ran, or on the first map after the
// plugin loaded) are kicked once, at map start, and the bot quota replaces them.
void StartReaddCheck()
{
	// A check still pending from an earlier run of the configs on this map
	delete g_hReaddTimer;

	if (!g_cvReadd.BoolValue)
	{
		strcopy(g_sReaddState, sizeof(g_sReaddState), "off (sm_adaptivebots_readd 0)");
		return;
	}

	g_iReaddChecks = 0;
	g_iReaddLastBots = -1;
	strcopy(g_sReaddState, sizeof(g_sReaddState), "waiting for the bots to join");
	g_hReaddTimer = CreateTimer(READD_CHECK_INTERVAL, Timer_ReaddCheck, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

int CountBots()
{
	int iBots = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && IsBot(client))
			iBots++;
	}
	return iBots;
}

public Action Timer_ReaddCheck(Handle timer)
{
	if (!IsDifficultyLeverOn() || !g_cvReadd.BoolValue)
	{
		strcopy(g_sReaddState, sizeof(g_sReaddState), "off");
		g_hReaddTimer = null;
		return Plugin_Stop;
	}

	int iBots = CountBots();
	g_iReaddChecks++;

	bool bStable = (iBots > 0 && iBots == g_iReaddLastBots);
	g_iReaddLastBots = iBots;
	if (!bStable && g_iReaddChecks < READD_MAX_CHECKS)
		return Plugin_Continue;

	g_hReaddTimer = null;
	ReaddMismatchedBots(iBots);
	return Plugin_Stop;
}

void ReaddMismatchedBots(int iBots)
{
	if (iBots == 0)
	{
		strcopy(g_sReaddState, sizeof(g_sReaddState), "no bot in game");
		return;
	}

	if (!g_bProfilesLoaded)
	{
		strcopy(g_sReaddState, sizeof(g_sReaddState), "skipped: the bot profile database could not be read");
		return;
	}

	// The quota only replaces kicked bots while the round is young (see READD_MAX_ROUND_TIME)
	if (FindEntityByClassname(-1, "cs_gamerules") == -1)
	{
		strcopy(g_sReaddState, sizeof(g_sReaddState), "skipped: no game rules entity");
		return;
	}

	float fRoundTime = GetGameTime() - GameRules_GetPropFloat("m_fRoundStartTime");
	if (fRoundTime > READD_MAX_ROUND_TIME)
	{
		FormatEx(g_sReaddState, sizeof(g_sReaddState), "skipped: the round was already %.0f s old", fRoundTime);
		LogReadd();
		return;
	}

	int iFlag = 1 << g_iDifficulty;

	// Every bot needs a free profile of the level, or the quota cannot add it back
	if (g_iPoolSize[g_iDifficulty] < iBots)
	{
		FormatEx(g_sReaddState, sizeof(g_sReaddState), "skipped: only %d %s profiles for %d bots", g_iPoolSize[g_iDifficulty], g_sDifficultyNames[g_iDifficulty], iBots);
		LogReadd();
		return;
	}

	int iMismatched = 0;
	int iUnknown = 0;
	char sName[MAX_NAME_LENGTH];
	int iFlags;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsBot(client) || IsClientInKickQueue(client))
			continue;

		GetClientName(client, sName, sizeof(sName));
		if (!GetProfileFlags(sName, iFlags))
		{
			iUnknown++;
			continue;
		}

		if (iFlags & iFlag)
			continue;

		KickClient(client, "%s", READD_KICK_REASON);
		iMismatched++;
	}

	if (iMismatched == 0)
		FormatEx(g_sReaddState, sizeof(g_sReaddState), "not needed: the %d bots match %s", iBots - iUnknown, g_sDifficultyNames[g_iDifficulty]);
	else
		FormatEx(g_sReaddState, sizeof(g_sReaddState), "%d of %d bots re-added as %s, %.0f s into the round", iMismatched, iBots, g_sDifficultyNames[g_iDifficulty], fRoundTime);

	if (iUnknown > 0)
		Format(g_sReaddState, sizeof(g_sReaddState), "%s (%d bot names not in the profile database)", g_sReaddState, iUnknown);

	LogReadd();
}

void LogReadd()
{
	if (g_cvDebug.IntValue >= 1)
		LogMessage("Map start bots: %s", g_sReaddState);
}

// ---------------------------------------------------------------------------------------------
// Bot profile database
// ---------------------------------------------------------------------------------------------

// Finds the difficulty flags of a bot from its name. Names are the profile names when bot_prefix
// is empty; with a prefix the profile name is the last word; "(1)" is added by the game when a
// player already has the name.
bool GetProfileFlags(const char[] sName, int &iFlags)
{
	if (g_smProfiles.GetValue(sName, iFlags))
		return true;

	int iStart = 0;
	if (sName[0] == '(')
	{
		int iClose = FindCharInString(sName, ')');
		if (iClose != -1)
			iStart = iClose + 1;
	}

	int iSpace = FindCharInString(sName[iStart], ' ', true);
	if (iSpace != -1)
		iStart += iSpace + 1;

	if (iStart == 0)
		return false;

	return g_smProfiles.GetValue(sName[iStart], iFlags);
}

void LoadBotProfiles()
{
	delete g_smProfiles;
	g_smProfiles = new StringMap();
	g_bProfilesLoaded = false;
	for (int i = 0; i < DIFFICULTY_LEVELS; i++)
		g_iPoolSize[i] = 0;

	// Same lookup as CCSBotManager::ServerActivate: the files listed in BotPackList.db, else
	// BotProfile.db, through the game file system (custom/ folders first, then the VPKs)
	ArrayList hFiles = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	if (!ReadTokens("BotPackList.db", hFiles))
		hFiles.PushString("BotProfile.db");

	char sFile[PLATFORM_MAX_PATH];
	for (int i = 0; i < hFiles.Length; i++)
	{
		hFiles.GetString(i, sFile, sizeof(sFile));
		ArrayList hTokens = new ArrayList(ByteCountToCells(64));
		if (ReadTokens(sFile, hTokens))
			ParseProfiles(sFile, hTokens);
		else
			LogError("Could not read the bot profile database %s", sFile);
		delete hTokens;
	}
	delete hFiles;

	StringMapSnapshot hSnapshot = g_smProfiles.Snapshot();
	char sName[MAX_NAME_LENGTH];
	int iFlags;
	for (int i = 0; i < hSnapshot.Length; i++)
	{
		hSnapshot.GetKey(i, sName, sizeof(sName));
		g_smProfiles.GetValue(sName, iFlags);
		for (int iLevel = 0; iLevel < DIFFICULTY_LEVELS; iLevel++)
		{
			if (iFlags & (1 << iLevel))
				g_iPoolSize[iLevel]++;
		}
	}
	delete hSnapshot;

	g_bProfilesLoaded = (g_smProfiles.Size > 0);

	int iQuota = g_cvBotQuota.IntValue;
	for (int iLevel = 0; iLevel < DIFFICULTY_LEVELS; iLevel++)
	{
		if (g_bProfilesLoaded && g_iPoolSize[iLevel] < iQuota)
			LogMessage("Only %d bot profiles are %s for bot_quota %d: at this bot_difficulty the quota cannot be filled", g_iPoolSize[iLevel], g_sDifficultyNames[iLevel], iQuota);
	}
}

// Reads a whitespace separated file with // comments into tokens; '=' is always its own token
bool ReadTokens(const char[] sFile, ArrayList hTokens)
{
	File hFile = OpenFile(sFile, "r", true);
	if (hFile == null)
	{
		// The game file system is case-insensitive on Linux, try the lower case name anyway
		char sLower[PLATFORM_MAX_PATH];
		strcopy(sLower, sizeof(sLower), sFile);
		for (int i = 0; sLower[i] != '\0'; i++)
			sLower[i] = CharToLower(sLower[i]);

		hFile = OpenFile(sLower, "r", true);
		if (hFile == null)
			return false;
	}

	char sLine[512];
	char sToken[64];
	while (hFile.ReadLine(sLine, sizeof(sLine)))
	{
		int iComment = StrContains(sLine, "//");
		if (iComment != -1)
			sLine[iComment] = '\0';

		ReplaceString(sLine, sizeof(sLine), "=", " = ");
		TrimString(sLine);

		int iPos = 0;
		while (sLine[iPos] != '\0')
		{
			int iNext = BreakString(sLine[iPos], sToken, sizeof(sToken));
			if (sToken[0] != '\0')
				hTokens.PushString(sToken);

			if (iNext == -1)
				break;
			iPos += iNext;
		}
	}

	delete hFile;
	return true;
}

int ParseDifficultyFlags(const char[] sValue)
{
	char sParts[DIFFICULTY_LEVELS][16];
	int iParts = ExplodeString(sValue, "+", sParts, sizeof(sParts), sizeof(sParts[]));
	int iFlags = 0;

	for (int i = 0; i < iParts; i++)
	{
		for (int iLevel = 0; iLevel < DIFFICULTY_LEVELS; iLevel++)
		{
			if (StrEqual(sParts[i], g_sDifficultyNames[iLevel], false))
				iFlags |= (1 << iLevel);
		}
	}
	return iFlags;
}

// Follows BotProfileManager::Init (shared/cstrike/bot/bot_profile.cpp), difficulty only:
// - "Default ... End" is the baseline of every template and profile;
// - "Template <Name> ... End" starts from Default;
// - "<Template>+<Template> <Name> ... End" starts from Default, then each template in order
//   overrides the difficulty when its own differs from Default (BotProfile::Inherit), then the
//   profile's own "Difficulty =" line overrides everything;
// - "Skin <Name> Model = <model> End" defines a custom skin and is skipped.
void ParseProfiles(const char[] sFile, ArrayList hTokens)
{
	StringMap hTemplates = new StringMap();
	int iDefaultFlags = 0;
	int iCount = hTokens.Length;
	int i = 0;

	char sHead[64], sName[64], sKey[64], sValue[64], sLower[64];
	char sTemplates[8][64];

	while (i < iCount)
	{
		hTokens.GetString(i++, sHead, sizeof(sHead));

		bool bDefault = StrEqual(sHead, "Default", false);
		bool bTemplate = StrEqual(sHead, "Template", false);
		bool bSkin = StrEqual(sHead, "Skin", false);

		if (!bDefault)
		{
			if (i >= iCount)
				break;
			hTokens.GetString(i++, sName, sizeof(sName));
		}

		int iOwnFlags = -1;
		bool bEnded = false;
		while (i < iCount)
		{
			hTokens.GetString(i++, sKey, sizeof(sKey));
			if (StrEqual(sKey, "End"))
			{
				bEnded = true;
				break;
			}

			// <key> = <value>
			if (i + 1 >= iCount)
				break;
			i++;
			hTokens.GetString(i++, sValue, sizeof(sValue));

			if (StrEqual(sKey, "Difficulty", false))
				iOwnFlags = ParseDifficultyFlags(sValue);
		}

		if (!bEnded)
		{
			LogError("Error parsing %s: block \"%s %s\" has no End", sFile, sHead, bDefault ? "" : sName);
			break;
		}

		if (bSkin)
			continue;

		if (bDefault)
		{
			if (iOwnFlags != -1)
				iDefaultFlags = iOwnFlags;
			continue;
		}

		if (bTemplate)
		{
			LowerCase(sName, sLower, sizeof(sLower));
			hTemplates.SetValue(sLower, iOwnFlags != -1 ? iOwnFlags : iDefaultFlags);
			continue;
		}

		int iFlags = iDefaultFlags;
		int iParts = ExplodeString(sHead, "+", sTemplates, sizeof(sTemplates), sizeof(sTemplates[]));
		for (int j = 0; j < iParts; j++)
		{
			int iTemplateFlags;
			LowerCase(sTemplates[j], sLower, sizeof(sLower));
			if (!hTemplates.GetValue(sLower, iTemplateFlags))
			{
				LogError("Error parsing %s: profile %s uses the unknown template %s", sFile, sName, sTemplates[j]);
				continue;
			}

			if (iTemplateFlags != iDefaultFlags)
				iFlags = iTemplateFlags;
		}

		if (iOwnFlags != -1)
			iFlags = iOwnFlags;

		g_smProfiles.SetValue(sName, iFlags);
	}

	delete hTemplates;
}

void LowerCase(const char[] sInput, char[] sOutput, int iMaxLen)
{
	int i = 0;
	for (; sInput[i] != '\0' && i < iMaxLen - 1; i++)
		sOutput[i] = CharToLower(sInput[i]);
	sOutput[i] = '\0';
}

// ---------------------------------------------------------------------------------------------
// Admin commands
// ---------------------------------------------------------------------------------------------

void StatusLine(int client, const char[] sFormat, any ...)
{
	char sBuffer[512];
	VFormat(sBuffer, sizeof(sBuffer), sFormat, 3);

	if (client == 0)
		PrintToServer("%s", sBuffer);
	else
		PrintToConsole(client, "%s", sBuffer);
}

public Action Command_Status(int client, int args)
{
	if (client != 0 && GetCmdReplySource() == SM_REPLY_TO_CHAT)
		ReplyToCommand(client, "[AdaptiveBots] See console for output.");

	StatusLine(client, "[AdaptiveBots] %s, version %s", g_cvEnable.BoolValue ? "enabled" : "disabled", PLUGIN_VERSION);

	int iCvar = g_cvBotDifficulty.IntValue;
	if (iCvar < 0 || iCvar >= DIFFICULTY_LEVELS)
		iCvar = DIFFICULTY_LEVELS - 1;

	if (!IsDifficultyLeverOn())
		StatusLine(client, "bot_difficulty %d (%s): not managed (sm_adaptivebots_enable or sm_adaptivebots_difficulty is 0)", g_cvBotDifficulty.IntValue, g_sDifficultyNames[iCvar]);
	else if (g_iDifficulty == DIFFICULTY_NONE)
		StatusLine(client, "bot_difficulty %d (%s): not chosen yet (chosen when the configs run at map start)", g_cvBotDifficulty.IntValue, g_sDifficultyNames[iCvar]);
	else
		StatusLine(client, "bot_difficulty %d (%s), chosen for this map: %s", g_cvBotDifficulty.IntValue, g_sDifficultyNames[iCvar], g_sDifficultyReason);

	StatusLine(client, "Bot profiles per level: EASY %d, NORMAL %d, HARD %d, EXPERT %d (bot_quota %d)",
		g_iPoolSize[0], g_iPoolSize[1], g_iPoolSize[2], g_iPoolSize[3], g_cvBotQuota.IntValue);
	StatusLine(client, "Map start re-add: %s", g_sReaddState);

	float fGroup;
	int iHumans = GetGroupRating(fGroup);
	int iNext = GetLevelForRating(fGroup);
	if (iHumans == 0)
		iNext = g_cvDifficultyDefault.IntValue;
	StatusLine(client, "Average rating now: %.2f from %d human(s) on a team (plain thresholds give %s, before hysteresis)", fGroup, iHumans, g_sDifficultyNames[iNext]);

	StatusLine(client, "%-32s %7s %7s %7s %9s %9s", "Name", "Rating", "Kills", "Deaths", "BotDmg x", "ToBots x");

	char sName[MAX_NAME_LENGTH];
	int iListed = 0;
	for (int target = 1; target <= MaxClients; target++)
	{
		if (!IsClientInGame(target) || IsFakeClient(target))
			continue;

		GetClientName(target, sName, sizeof(sName));
		StatusLine(client, "%-32s %7.2f %7.1f %7.1f %9.2f %9.2f%s", sName, GetRating(target), g_fKills[target], g_fDeaths[target],
			GetDamageMultiplier(target), GetReverseMultiplier(target), g_bRatingLoaded[target] ? "" : "  (rating not loaded yet)");
		iListed++;
	}

	if (iListed == 0)
		StatusLine(client, "No human in game.");

	return Plugin_Handled;
}

public Action Command_SetRating(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[AdaptiveBots] Usage: sm_adaptivebots_setrating <target> <rating> (1.0 = average, %.1f to %.1f)", RATING_MIN, RATING_MAX);
		return Plugin_Handled;
	}

	char sTarget[MAX_TARGET_LENGTH], sValue[16];
	GetCmdArg(1, sTarget, sizeof(sTarget));
	GetCmdArg(2, sValue, sizeof(sValue));

	float fRating = StringToFloat(sValue);
	if (fRating < RATING_MIN)
		fRating = RATING_MIN;
	else if (fRating > RATING_MAX)
		fRating = RATING_MAX;

	char sTargetName[MAX_TARGET_LENGTH];
	int iTargets[MAXPLAYERS];
	bool bTnIsMl;
	int iCount = ProcessTargetString(sTarget, client, iTargets, sizeof(iTargets), COMMAND_FILTER_NO_BOTS, sTargetName, sizeof(sTargetName), bTnIsMl);
	if (iCount <= 0)
	{
		ReplyToTargetError(client, iCount);
		return Plugin_Handled;
	}

	for (int i = 0; i < iCount; i++)
	{
		SetRating(iTargets[i], fRating);
		ReplyToCommand(client, "[AdaptiveBots] %N: rating %.2f, bot damage x%.2f, damage to bots x%.2f%s", iTargets[i], GetRating(iTargets[i]),
			GetDamageMultiplier(iTargets[i]), GetReverseMultiplier(iTargets[i]), AreClientCookiesCached(iTargets[i]) ? "" : " (not saved: cookies not loaded yet)");
	}

	LogAction(client, -1, "\"%L\" set the AdaptiveBots rating of %s to %.2f", client, sTargetName, fRating);
	return Plugin_Handled;
}
