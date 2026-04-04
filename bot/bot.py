"""
LadderTracker Discord Bot

Slash commands:
  /register   <battletag> <race> [region]  - Add a race to tracking (supports multiple per user)
  /unregister [race]                       - Remove one or all tracked races
  /update-race <old_race> <new_race>       - Swap a race while preserving history
  /players                                 - List all registered players grouped by user
  /status                                  - Show last/next run info and player counts
  /run                                     - (Admin) Force an immediate run
  /update-league <league_name> <min_mmr>   - (Admin) Update an MMR threshold
  /list-leagues                            - Show current league thresholds
"""

import os
import asyncio
import aiohttp
import pyodbc
import discord
from discord import app_commands
from discord.ext import commands
from datetime import datetime, timezone, timedelta
from collections import defaultdict

# ── Configuration ─────────────────────────────────────────────────────────────
DISCORD_TOKEN   = os.environ["DISCORD_TOKEN"]
GUILD_ID        = int(os.environ["DISCORD_GUILD_ID"])
ADMIN_ROLE_NAME = os.environ.get("ADMIN_ROLE_NAME", "Admin")
SQL_SERVER      = os.environ.get("SQL_SERVER", "sqlserver")
SQL_USER        = os.environ.get("SQL_USER", "sa")
SQL_PASS        = os.environ.get("SQL_PASS", "")
SQL_DATABASE    = "FxB_LadderLeaderboard"
SC2PULSE_BASE   = "https://sc2pulse.nephest.com/sc2/api"

VALID_RACES   = ["ZERG", "TERRAN", "PROTOSS", "RANDOM"]
VALID_REGIONS = {"US": 1, "EU": 2, "KR": 3}

RACE_EMOJI = {
    "ZERG":    "\U0001F7E3",  # purple circle
    "TERRAN":  "\U0001F535",  # blue circle
    "PROTOSS": "\U0001F7E1",  # yellow circle
    "RANDOM":  "\u26AA",      # white circle
}

# ── Database ──────────────────────────────────────────────────────────────────
def get_conn():
    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={SQL_SERVER};"
        f"DATABASE={SQL_DATABASE};"
        f"UID={SQL_USER};"
        f"PWD={SQL_PASS};"
        f"TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str)


def db_get_all_players():
    """Return all active player rows, ordered by name then race."""
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT LLID, DiscordID, NephestID, Name, Race, BattleTag, Region
            FROM Players WHERE Active = 1
            ORDER BY Name, Race
        """)
        return cursor.fetchall()


def db_get_player_registrations(discord_id: str):
    """Return all active rows for a given Discord user."""
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT LLID, Race, Name, BattleTag, Region
            FROM Players WHERE DiscordID = ? AND Active = 1
        """, discord_id)
        return cursor.fetchall()


def db_get_player_by_llid(llid: str):
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT LLID, Name, Race, BattleTag FROM Players WHERE LLID = ? AND Active = 1",
            llid
        )
        return cursor.fetchone()


def db_add_player(llid, discord_id, nephest_id, name, race, battletag, region):
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            MERGE Players AS target
            USING (SELECT ? AS LLID) AS source ON target.LLID = source.LLID
            WHEN MATCHED THEN
                UPDATE SET DiscordID = ?, NephestID = ?, Name = ?, Race = ?,
                           BattleTag = ?, Region = ?, Active = 1, AddedDate = GETDATE()
            WHEN NOT MATCHED THEN
                INSERT (LLID, DiscordID, NephestID, Name, Race, BattleTag, Region, Active, AddedDate)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, GETDATE());
        """, llid, discord_id, nephest_id, name, race, battletag, region,
             llid, discord_id, nephest_id, name, race, battletag, region)
        conn.commit()


def db_remove_player(llid: str) -> bool:
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE Players SET Active = 0 WHERE LLID = ?", llid)
        rows = cursor.rowcount
        conn.commit()
        return rows > 0


def db_remove_all_for_user(discord_id: str) -> int:
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE Players SET Active = 0 WHERE DiscordID = ? AND Active = 1", discord_id)
        rows = cursor.rowcount
        conn.commit()
        return rows


def db_update_race(old_llid: str, new_llid: str, new_race: str) -> bool:
    """Rename a player's race registration, migrating all historical data."""
    with get_conn() as conn:
        cursor = conn.cursor()
        # Check new LLID doesn't already exist as an active registration
        cursor.execute("SELECT 1 FROM Players WHERE LLID = ? AND Active = 1", new_llid)
        if cursor.fetchone():
            return False
        cursor.execute("UPDATE Players          SET LLID = ?, Race = ? WHERE LLID = ?", new_llid, new_race, old_llid)
        cursor.execute("UPDATE AllParticipants  SET LLID = ?            WHERE LLID = ?", new_llid, old_llid)
        cursor.execute("UPDATE LadderHistory    SET LLID = ?            WHERE LLID = ?", new_llid, old_llid)
        conn.commit()
        return True


def db_get_run_control():
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT ForceRun, LastRunTime, LastRunStatus, LastRunPlayers, LastRunError, RunHour FROM RunControl WHERE ID = 1")
        return cursor.fetchone()


def db_set_force_run():
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE RunControl SET ForceRun = 1 WHERE ID = 1")
        conn.commit()


def db_get_league_thresholds():
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT LeagueName, ShortName, MinMMR, SortOrder FROM LeagueThresholds ORDER BY MinMMR DESC")
        return cursor.fetchall()


def db_update_league_threshold(league_name: str, min_mmr: int) -> bool:
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE LeagueThresholds SET MinMMR = ? WHERE LeagueName = ?", min_mmr, league_name)
        rows = cursor.rowcount
        conn.commit()
        return rows > 0


def db_count_players():
    with get_conn() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM Players WHERE Active = 1")
        return cursor.fetchone()[0]


# ── SC2Pulse API ──────────────────────────────────────────────────────────────
async def sc2pulse_search(name: str, region: str = "US") -> list[dict]:
    """
    Search SC2Pulse for a player by name within a region.
    Returns a normalized list of dicts with 'id' and 'name' keys.
    Logs the raw response so we can diagnose unexpected structures.
    """
    region_id = VALID_REGIONS.get(region.upper(), 1)
    url = f"{SC2PULSE_BASE}/character/search"
    params = {"term": name, "region": region_id}

    async with aiohttp.ClientSession() as session:
        async with session.get(url, params=params, timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status != 200:
                print(f"[Search] HTTP {resp.status} for term={name} region={region_id}")
                return []
            data = await resp.json()

    # Log raw structure so we can see exactly what SC2Pulse returns
    print(f"[Search] Raw response: {str(data)[:800]}")

    if not data:
        return []

    results = []
    items = data if isinstance(data, list) else [data]

    for item in items:
        # Actual SC2Pulse structure:
        # {"members": {"character": {"id": ..., "name": "Tag#1234", "tag": "Tag"}}}
        members = item.get("members")
        if members and isinstance(members, dict):
            char = members.get("character", {})
            char_id   = char.get("id")
            char_name = char.get("name") or char.get("tag")
            if char_id and char_name:
                results.append({"id": char_id, "name": char_name})
                continue

        # Fallback: flat structure {"id": ..., "name": ...}
        if "id" in item and "name" in item:
            results.append({"id": item["id"], "name": item["name"]})
            continue

        print(f"[Search] Unrecognized item structure: {str(item)[:300]}")

    print(f"[Search] Normalized {len(results)} result(s) from {len(items)} item(s)")
    return results


# ── Bot Setup ─────────────────────────────────────────────────────────────────
intents = discord.Intents.default()
bot     = commands.Bot(command_prefix="!", intents=intents)
guild   = discord.Object(id=GUILD_ID)


def is_admin(interaction: discord.Interaction) -> bool:
    return any(r.name == ADMIN_ROLE_NAME for r in interaction.user.roles)


# ── /register ─────────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="register", description="Add a race to the FxB ladder tracker. You can register multiple races.")
@app_commands.describe(
    battletag="Your BattleTag (e.g. PlayerName#1234)",
    race="The race you want to track",
    region="Your server region"
)
@app_commands.choices(
    race=[app_commands.Choice(name=r, value=r) for r in VALID_RACES],
    region=[app_commands.Choice(name=r, value=r) for r in VALID_REGIONS]
)
async def register(interaction: discord.Interaction, battletag: str, race: str, region: str = "US"):
    await interaction.response.defer(ephemeral=True)

    discord_id = str(interaction.user.id)
    race       = race.upper()
    llid       = f"{discord_id}_{race}"

    # Check if this exact race is already registered
    existing = db_get_player_by_llid(llid)
    if existing:
        await interaction.followup.send(
            f"You're already tracking **{race}** as **{existing[1]}**. "
            f"Use `/update-race` to change race, or `/unregister` to remove it.",
            ephemeral=True
        )
        return

    # Search SC2Pulse
    name = battletag.split("#")[0]
    try:
        results = await sc2pulse_search(name, region)
    except Exception as e:
        await interaction.followup.send(f"SC2Pulse search failed: `{e}`", ephemeral=True)
        return

    if not results:
        await interaction.followup.send(
            f"No players found for `{battletag}` on `{region}`. "
            f"Check your BattleTag and region and try again.",
            ephemeral=True
        )
        return

    # Narrow to exact battletag match if # included
    if "#" in battletag:
        tag_lower = battletag.lower()
        exact = [r for r in results if r.get("name", "").lower() == tag_lower]
        candidates = exact if exact else results[:5]
    else:
        candidates = results[:5]

    if len(candidates) == 1:
        chosen = candidates[0]
        display = chosen.get("name", battletag).split("#")[0]
        await _confirm_register(interaction, llid, discord_id, chosen["id"], display, race, battletag, region)
    else:
        view  = PlayerSelectView(candidates, llid, discord_id, race, battletag, region)
        lines = [f"`{i+1}.` **{c.get('name','?')}** — ID `{c.get('id')}`"
                 for i, c in enumerate(candidates)]
        await interaction.followup.send(
            f"Found {len(candidates)} matches for `{name}`. Select the correct player:\n" +
            "\n".join(lines),
            view=view,
            ephemeral=True
        )


async def _confirm_register(interaction, llid, discord_id, nephest_id, display_name, race, battletag, region):
    try:
        db_add_player(llid, discord_id, nephest_id, display_name, race, battletag, region)
    except Exception as e:
        await interaction.followup.send(f"Database error: `{e}`", ephemeral=True)
        return

    # Show all races this user now has registered
    all_regs = db_get_player_registrations(discord_id)
    reg_list = ", ".join(f"{RACE_EMOJI.get(r[1], '')} {r[1]}" for r in all_regs)

    embed = discord.Embed(
        title=f"{RACE_EMOJI.get(race, '')} Registered!",
        description=f"**{display_name}** is now tracking **{race}** ({region}).",
        color=discord.Color.green()
    )
    embed.add_field(name="All your tracked races", value=reg_list or "None", inline=False)
    embed.set_footer(text=f"NephestID: {nephest_id} | You'll appear in tomorrow's report.")
    await interaction.followup.send(embed=embed, ephemeral=True)


class PlayerSelectView(discord.ui.View):
    def __init__(self, candidates, llid, discord_id, race, battletag, region):
        super().__init__(timeout=60)
        for i, c in enumerate(candidates[:5]):
            btn = discord.ui.Button(
                label=c.get("name", f"Player {i+1}"),
                style=discord.ButtonStyle.primary
            )
            btn.callback = self._make_cb(c, llid, discord_id, race, battletag, region)
            self.add_item(btn)

    def _make_cb(self, candidate, llid, discord_id, race, battletag, region):
        async def cb(interaction: discord.Interaction):
            await interaction.response.defer(ephemeral=True)
            display = candidate.get("name", battletag).split("#")[0]
            await _confirm_register(interaction, llid, discord_id, candidate["id"], display, race, battletag, region)
            self.stop()
        return cb


# ── /unregister ───────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="unregister", description="Remove one or all of your tracked races.")
@app_commands.describe(discord_user="(Admin only) Remove a different user's registration.")
async def unregister(interaction: discord.Interaction, discord_user: discord.Member = None):
    await interaction.response.defer(ephemeral=True)

    if discord_user and discord_user.id != interaction.user.id:
        if not is_admin(interaction):
            await interaction.followup.send("You need the Admin role to remove other players.", ephemeral=True)
            return
        target_id    = str(discord_user.id)
        target_label = discord_user.display_name
    else:
        target_id    = str(interaction.user.id)
        target_label = interaction.user.display_name

    registrations = db_get_player_registrations(target_id)
    if not registrations:
        await interaction.followup.send(f"**{target_label}** has no active registrations.", ephemeral=True)
        return

    if len(registrations) == 1:
        # Single race - confirm and remove immediately
        r = registrations[0]
        db_remove_player(r[0])
        await interaction.followup.send(
            f"Removed **{r[2]}** ({r[1]}) from the tracker.", ephemeral=True
        )
    else:
        # Multiple races - show select menu
        view = UnregisterSelectView(registrations, target_id, target_label)
        lines = [f"{RACE_EMOJI.get(r[1],'')} **{r[1]}** ({r[4]})" for r in registrations]
        await interaction.followup.send(
            f"**{target_label}** has {len(registrations)} registered races. Which should be removed?",
            view=view,
            ephemeral=True
        )


class UnregisterSelectView(discord.ui.View):
    def __init__(self, registrations, discord_id, label):
        super().__init__(timeout=60)
        options = [
            discord.SelectOption(
                label=f"{r[1]} ({r[4]})",
                value=r[0],
                emoji=RACE_EMOJI.get(r[1])
            )
            for r in registrations
        ]
        options.append(discord.SelectOption(label="All Races", value="__ALL__", emoji="\U0001F5D1"))

        select = discord.ui.Select(placeholder="Choose race(s) to remove", options=options)
        select.callback = self._make_cb(discord_id, label)
        self.add_item(select)

    def _make_cb(self, discord_id, label):
        async def cb(interaction: discord.Interaction):
            value = interaction.data["values"][0]
            if value == "__ALL__":
                count = db_remove_all_for_user(discord_id)
                await interaction.response.send_message(
                    f"Removed all {count} race registration(s) for **{label}**.", ephemeral=True
                )
            else:
                player = db_get_player_by_llid(value)
                db_remove_player(value)
                name = player[1] if player else label
                race = player[2] if player else value.split("_")[-1]
                await interaction.response.send_message(
                    f"Removed **{name}** ({race}) from the tracker.", ephemeral=True
                )
            self.stop()
        return cb


# ── /update-race ──────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="update-race", description="Change one of your tracked races without losing your MMR history.")
@app_commands.describe(
    old_race="The race you currently have registered that you want to change",
    new_race="The race you want to track instead"
)
@app_commands.choices(
    old_race=[app_commands.Choice(name=r, value=r) for r in VALID_RACES],
    new_race=[app_commands.Choice(name=r, value=r) for r in VALID_RACES]
)
async def update_race(interaction: discord.Interaction, old_race: str, new_race: str):
    await interaction.response.defer(ephemeral=True)

    discord_id = str(interaction.user.id)

    if old_race == new_race:
        await interaction.followup.send("Old and new race are the same.", ephemeral=True)
        return

    old_race = old_race.upper()
    new_race = new_race.upper()
    old_llid = f"{discord_id}_{old_race}"
    new_llid = f"{discord_id}_{new_race}"

    if not db_get_player_by_llid(old_llid):
        await interaction.followup.send(
            f"You don't have **{old_race}** registered. Use `/players` to see your current registrations.",
            ephemeral=True
        )
        return

    success = db_update_race(old_llid, new_llid, new_race)
    if success:
        await interaction.followup.send(
            f"Updated: **{old_race}** has been changed to **{new_race}**. "
            f"Your MMR history has been carried over.",
            ephemeral=True
        )
    else:
        await interaction.followup.send(
            f"Could not update - you may already have **{new_race}** registered. "
            f"Use `/unregister` to remove it first.",
            ephemeral=True
        )


# ── /players ──────────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="players", description="List all players currently tracked, grouped by user.")
async def players(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)

    rows = db_get_all_players()
    if not rows:
        await interaction.followup.send(
            "No players registered yet. Use `/register` to add yourself!", ephemeral=True
        )
        return

    # Group by Discord user (Name)
    by_name = defaultdict(list)
    for r in rows:
        # r: LLID, DiscordID, NephestID, Name, Race, BattleTag, Region
        by_name[r[3]].append(f"{RACE_EMOJI.get(r[4], '')} {r[4]} ({r[6]})")

    lines = []
    for name, race_list in by_name.items():
        races = " | ".join(race_list)
        lines.append(f"**{name}** - {races}")

    total_entries = len(rows)
    total_players = len(by_name)

    embed = discord.Embed(
        title=f"FxB Ladder Tracker - {total_players} Player(s), {total_entries} Tracked Race(s)",
        description="\n".join(lines),
        color=discord.Color.blurple()
    )
    await interaction.followup.send(embed=embed, ephemeral=True)


# ── /status ───────────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="status", description="Show the last run result and next scheduled run.")
async def status(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)

    try:
        control = db_get_run_control()
    except Exception as e:
        await interaction.followup.send(f"Could not read status: `{e}`", ephemeral=True)
        return

    # control: ForceRun, LastRunTime, LastRunStatus, LastRunPlayers, LastRunError, RunHour
    run_hour      = control[5] if control[5] is not None else 23
    last_time     = control[1]
    last_status   = control[2] or "Never run"
    last_players  = control[3]
    last_error    = control[4]

    now       = datetime.now(timezone.utc)
    scheduled = now.replace(hour=run_hour, minute=0, second=0, microsecond=0)
    if now >= scheduled:
        scheduled += timedelta(days=1)
    time_until = scheduled - now
    hours, rem = divmod(int(time_until.total_seconds()), 3600)
    mins       = rem // 60

    status_emoji = {"Success": "\u2705", "Failed": "\u274C", "Running": "\u23F3"}.get(last_status, "\u2753")

    last_run_str = (
        f"<t:{int(last_time.timestamp())}:F>" if last_time else "Never"
    ) if last_time else "Never"

    player_count = db_count_players()

    embed = discord.Embed(title="LadderTracker Status", color=discord.Color.blurple())
    embed.add_field(name="Last Run",     value=last_run_str,                         inline=False)
    embed.add_field(name="Status",       value=f"{status_emoji} {last_status}",      inline=True)
    embed.add_field(name="Processed",    value=str(last_players) if last_players is not None else "N/A", inline=True)
    embed.add_field(name="Registered",   value=f"{player_count} active race(s)",     inline=True)
    embed.add_field(name="Next Run",     value=f"<t:{int(scheduled.timestamp())}:R> ({hours}h {mins}m)", inline=False)

    if last_error:
        embed.add_field(name="Last Error", value=f"```{last_error[:512]}```", inline=False)

    await interaction.followup.send(embed=embed, ephemeral=True)


# ── /run (admin) ──────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="run", description="(Admin) Force an immediate ladder tracker run.")
async def force_run(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)

    if not is_admin(interaction):
        await interaction.followup.send("You need the Admin role to use this command.", ephemeral=True)
        return

    try:
        db_set_force_run()
        await interaction.followup.send(
            "Force-run flag set. The tracker will start within 60 seconds.\n"
            "Use `/status` to monitor the result.",
            ephemeral=True
        )
    except Exception as e:
        await interaction.followup.send(f"Failed to set force-run: `{e}`", ephemeral=True)


# ── /update-league (admin) ────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="update-league", description="(Admin) Update the minimum MMR for a league division.")
@app_commands.describe(
    league_name="Full league name, e.g. 'Gold 3' or 'Diamond 1'",
    min_mmr="New minimum MMR for this division"
)
async def update_league(interaction: discord.Interaction, league_name: str, min_mmr: int):
    await interaction.response.defer(ephemeral=True)

    if not is_admin(interaction):
        await interaction.followup.send("You need the Admin role to use this command.", ephemeral=True)
        return

    if min_mmr < 0 or min_mmr > 10000:
        await interaction.followup.send("MMR value must be between 0 and 10000.", ephemeral=True)
        return

    success = db_update_league_threshold(league_name, min_mmr)
    if success:
        await interaction.followup.send(
            f"Updated **{league_name}** minimum MMR to **{min_mmr}**.\n"
            f"This takes effect on the next tracker run. Use `/list-leagues` to verify.",
            ephemeral=True
        )
    else:
        await interaction.followup.send(
            f"League `{league_name}` not found. Use `/list-leagues` to see valid names.",
            ephemeral=True
        )


# ── /list-leagues ─────────────────────────────────────────────────────────────
@bot.tree.command(guild=guild, name="list-leagues", description="Show current league MMR thresholds.")
async def list_leagues(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)

    try:
        rows = db_get_league_thresholds()
    except Exception as e:
        await interaction.followup.send(f"Could not load thresholds: `{e}`", ephemeral=True)
        return

    # Group by ShortName
    by_league = defaultdict(list)
    for r in rows:
        # r: LeagueName, ShortName, MinMMR, SortOrder
        by_league[r[1]].append(f"  {r[0]}: {r[2]:,}+")

    lines = []
    seen  = set()
    # Preserve order from highest to lowest
    for r in rows:
        short = r[1]
        if short not in seen:
            seen.add(short)
            lines.append(f"**{short}**")
            lines.extend(by_league[short])

    embed = discord.Embed(
        title="League MMR Thresholds (Americas)",
        description="\n".join(lines),
        color=discord.Color.blurple()
    )
    embed.set_footer(text="Use /update-league to adjust thresholds each new season.")
    await interaction.followup.send(embed=embed, ephemeral=True)


# ── Startup ───────────────────────────────────────────────────────────────────
@bot.event
async def on_ready():
    print(f"[Bot] Logged in as {bot.user} (ID: {bot.user.id})")
    try:
        synced = await bot.tree.sync(guild=guild)
        print(f"[Bot] Synced {len(synced)} slash command(s) to guild {GUILD_ID}.")
    except Exception as e:
        print(f"[Bot] Failed to sync commands: {e}")


if __name__ == "__main__":
    bot.run(DISCORD_TOKEN)