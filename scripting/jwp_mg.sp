#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <jwp>
#include <emitsoundany>
#include <hosties>
#include <lastrequest>

// Force 1.7 syntax
#pragma newdecls required

#define PLUGIN_VERSION "1.0"
#define ITEM "mg"

bool g_bIsCSGO;

int g_iGameMode = -1, g_iGameId = -1;
bool g_bIsGameRunning = false;
bool g_bEnabled;

char g_cGameName[32], g_cGameRules[192], g_cMusicAll[PLATFORM_MAX_PATH];
int g_iWaitTimerT, g_iWaitTimerCT;
KeyValues g_KvConfig;

// Menu restrictions
int g_iMapLimit, g_iMapLimitCounter;
int g_iCoolDown, g_iCoolDownCounter;
bool g_bGamePassed;

Handle g_hTerTimer, g_hCtTimer, g_hWhistleCooldown[MAXPLAYERS+1];

// Zombie velocity
int g_iToolsVelocity;
// Collision off
int g_CollisionGroupOffset;

// Weapon & Ammo offsets
int g_iClipOffset, g_iAmmoOffset, g_iPrimaryAmmoTypeOffset, g_iActiveWeaponOffset;

public Plugin myinfo =
{
	name = "[JWP] MultiGames",
	description = "Minigames for Jail Warden Pro",
	author = "White Wolf, BaFeR",
	version = PLUGIN_VERSION,
	url = "http://tibari.ru"
};

#include "jwp/mg/cvars.sp"
#include "jwp/mg/kv_config.sp"
#include "jwp/mg/menu.sp"
#include "jwp/mg/functions.sp"
#include "jwp/mg/games/zombie.sp"
#include "jwp/mg/games/hidenseek.sp"
#include "jwp/mg/games/chickenhunt.sp"
#include "jwp/mg/games/hotpotato.sp"
#include "jwp/mg/games/zeusdm.sp"
#include "jwp/mg/games/catchnfree.sp"
#include "jwp/mg/events.sp"

public void OnPluginStart()
{
	if (GetEngineVersion() == Engine_CSGO)
		g_bIsCSGO = true;
	else g_bIsCSGO = false;
	
	g_iClipOffset = FindSendPropInfo("CBaseCombatWeapon", "m_iClip1");
	g_iAmmoOffset = FindSendPropInfo("CCSPlayer", "m_iAmmo");
	g_iPrimaryAmmoTypeOffset = FindSendPropInfo("CBaseCombatWeapon", "m_iPrimaryAmmoType");
	g_iActiveWeaponOffset = FindSendPropInfo("CCSPlayer", "m_hActiveWeapon");
	
	if (g_iClipOffset == -1)
		SetFailState("Failed to get m_iClip1 offset");
	else if (g_iAmmoOffset == -1)
		SetFailState("Failed to get m_iAmmo offset");
	else if (g_iPrimaryAmmoTypeOffset == -1)
		SetFailState("Failed to get m_iPrimaryAmmoType offset");
	else if (g_iActiveWeaponOffset == -1)
		SetFailState("Failed to get m_hActiveWeapon offset");
	
	CvarInitialization();
	MenuInitialization();
	ReadGameModeConfigs();
	EventsInitialization();
	
	RegConsoleCmd("sm_mask", Command_Mask, "Pick up model for hidenseek");
	RegConsoleCmd("sm_whistle", Command_Whistle, "Whistle for hidenseek or chickenhunt");
	RegConsoleCmd("sm_lr", Listener_LRCommand); // AddCommandListener not block this command
	
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
	
	g_CollisionGroupOffset = FindSendPropInfo("CBaseEntity", "m_CollisionGroup");
	if (g_CollisionGroupOffset == -1)
			LogError("CBaseEntity::m_CollisionGroup offset not found");
	
	if (JWP_IsStarted()) JWP_Started();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_iToolsVelocity = FindSendPropInfo("CBasePlayer", "m_vecVelocity[0]");
	
	if (g_iToolsVelocity == -1)
	{
		strcopy(error, err_max, "Offset \"CBasePlayer::m_vecVelocity[0]\" was not found.");
		return APLRes_Failure;
	}
	
	return APLRes_Success;
}

public void OnMapStart()
{
	if (g_bIsCSGO)
	{
		PrecacheModel("models/player/tm_phoenix.mdl");
		PrecacheModel("models/chicken/chicken.mdl", true);
	}
	else
		PrecacheModel("models/player/t_leet.mdl");
	
	g_iGameId = -1;
	g_iGameMode = -1;
	g_bIsGameRunning = false;
	
	PrecacheMusic();
	
	CreateDoorList();
}

public Action Command_Mask(int client, int args)
{
	if (client && IsClientInGame(client))
	{
		if (g_iGameMode != hidenseek)
		{
			PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только во время пряток.");
			return Plugin_Handled;
		}
		if (GetClientTeam(client) == CS_TEAM_T)
		{
			if (IsPlayerAlive(client))
			{
				int propLimit = g_KvConfig.GetNum("max_masks", 0);
				if (propLimit < 0) propLimit = 0;
				
				if (!propLimit || g_iMaxMasks[client] < propLimit)
					g_PropsMenu.Display(client, 20);
				else
					PrintToChat(client, "\x01[\x03JWP|MG|Прятки\x01] \x02Вы превысили лимит выбора предметов (%d/%d)", g_iMaxMasks[client], propLimit);
			}
			else
				PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только если вы живы.");
		}
		else
			PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только Террористам");
	}
	
	return Plugin_Handled;
}

public Action Command_Whistle(int client, int args)
{
	if (client && IsClientInGame(client))
	{
		if (g_iGameMode != hidenseek && g_iGameMode != chickenhunt)
		{
			PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только во время пряток или охоты.");
			return Plugin_Handled;
		}
		if (GetClientTeam(client) == CS_TEAM_T)
		{
			if (IsPlayerAlive(client))
			{
				if (g_hWhistleCooldown[client] == null)
				{
					g_hWhistleCooldown[client] = CreateTimer(15.0, WhistleCooldownTimer, client);
					PrintToChatAll("\x01[\x02JWP|MG\x01] \x03%N курлыкает.", client);
					EmitSoundToAllAny("tib/curlik.mp3", client);
				}
				else
					PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Курлык недоступен, попробуйте позже (15 с).");
			}
			else
				PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только если вы живы.");
		}
		else
			PrintToChat(client, "\x01[\x02JWP|MG\x01] \x02Данная команда доступна только Террористам");
	}
	
	return Plugin_Handled;
}

public Action WhistleCooldownTimer(Handle timer, any client)
{
	g_hWhistleCooldown[client] = null;
}

public Action Listener_LRCommand(int client, int args)
{
	if (g_iGameMode != -1)
	{
		if (client && IsClientInGame(client))
		{
			ReplyToCommand(client, "LR недоступен во время миниигр");
			return Plugin_Stop;
		}
	}
	return Plugin_Continue;
}

public void OnPluginEnd()
{
	JWP_RemoveFromMainMenu();
	if (g_MainMenu != null)
		delete g_MainMenu;
}