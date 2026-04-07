# Starcraft II Ladder Tracker

> A fully automated StarCraft II ladder tracking system for the **Formless Bearsloths** Discord community. Tracks daily MMR changes, win rates, streaks, league promotions, and more — all delivered directly to Discord and a self-hosted web dashboard.

---

## ✨ Features

- 📊 **Daily ladder reports** posted to Discord every night
- 🏆 **All-time high detection** — celebrates new personal bests
- ⬆️⬇️ **League promotion & demotion alerts** — division-level granularity
- 🔴 **Tilt detection** — flags players on active losing streaks
- 📈 **Weekly leaderboard** — net MMR gain/loss over 7 days
- 🌐 **Static web dashboard** — full leaderboard with no Discord character limits
- 🤖 **Discord slash commands** — self-service registration, no CSV editing required
- 🎭 **Multi-race support** — track Zerg, Terran, Protoss, and Random separately per player
- 💬 **Randomized flavor text** — race-aware, tiered commentary for winners and losers
- 🗄️ **Full MMR history** — per-player, per-day snapshots in SQL for trend analysis
- 🐳 **Fully Dockerized** — three containers, one compose file, runs anywhere

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────┐
│                   Docker Stack                       │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐   │
│  │  PowerShell  │  │    Python    │  │   nginx   │   │
│  │  Scheduler   │  │  Discord Bot │  │  Web UI   │   │
│  │              │  │              │  │           │   │
│  │ entrypoint   │  │   bot.py     │  │ index.html│   │
│  │ LadderTrack  │  │              │  │           │   │
│  └──────┬───────┘  └──────┬───────┘  └─────┬─────┘   │
│         │                 │                │         │
│         └────────┬────────┘                │         │
│                  ▼                         │         │
│         ┌────────────────┐                 │         │
│         │   SQL Server   │                 │         │
│         │     2022       │                 │         │
│         │                │                 │         │
│         │  Players       │                 │         │
│         │  LadderHistory │                 │         │
│         │  AllParticip.  │                 │         │
│         │  LadderStaging │                 │         │
│         │  LeagueThrshld │                 │         │
│         │  RunControl    │                 │         │
│         └────────────────┘                 │         │
│                                            │         │
└────────────────────────────────────────────┼─────────┘
                                             │
                                     ┌───────▼───────┐
                                     │    Traefik    │
                                     │ ladder.domain │
                                     └───────────────┘
```

**Data flow:** The PowerShell scheduler wakes up once daily, queries the SC2Pulse API for each registered player, writes results to SQL Server, and posts a single Discord embed. The nginx container serves a static HTML page generated each run. The Discord bot handles player registration and admin commands independently.

---

## 🤖 Discord Bot Commands

| Command | Description |
|---|---|
| `/register <battletag> <race> [region]` | Add a race to your tracking profile |
| `/unregister [race]` | Remove one or all of your tracked races |
| `/update-race <old> <new>` | Swap a race while preserving full MMR history |
| `/players` | List all registered players grouped by user |
| `/status` | Show last run result, player count, and next scheduled run |
| `/run` | *(Admin)* Force an immediate tracker run |
| `/update-league <name> <mmr>` | *(Admin)* Update an MMR threshold for a new season |
| `/list-leagues` | Show current league MMR thresholds |

---

## 📁 Project Structure

```
LadderTracker/
├── Dockerfile              # PowerShell app container
├── LadderTracker.ps1       # Main tracker script
├── entrypoint.ps1          # Scheduler, SQL bootstrap, log rotation
├── docker-compose.yml      # Full stack definition
├── bot/
│   ├── Dockerfile          # Python Discord bot container
│   ├── bot.py              # Slash command handler
│   └── requirements.txt    # Python dependencies
└── .env.example            # Environment variable template
```

---

## 🚀 Getting Started

### Prerequisites

- Docker + Docker Compose (or Portainer)
- A Discord server with Developer Mode enabled
- A Discord application with a bot token
- Optional: Traefik reverse proxy for HTTPS on the web dashboard

### 1. Clone the repository

```bash
git clone https://github.com/darinbolton/LadderTracker2.0.git
cd LadderTracker2.0
```

### 2. Configure environment variables

```bash
cp .env.example .env
nano .env
```

Fill in all values — see [Environment Variables](#-environment-variables) below.

### 3. Build the images

```bash
docker build -t laddertracker-app:latest .
docker build -t laddertracker-bot:latest ./bot
```

### 4. Create the data directory

```bash
mkdir -p /opt/laddertracker/data
```

### 5. Deploy

**Via Docker Compose:**
```bash
docker compose up -d
```

**Via Portainer:**
- Paste `docker-compose.yml` into the stack editor
- Add environment variables in the Portainer UI
- Deploy

### 6. Verify

```bash
# All three containers should be running
docker ps | grep ladder

# Watch the app container bootstrap the database
docker logs laddertracker-app -f
```

Once `laddertracker-bot` logs show `Synced 8 slash command(s)`, go to your Discord server and run `/players` to confirm end-to-end connectivity.

---

## ⚙️ Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DISCORD_WEBHOOK` | ✅ | Webhook URL for daily report embeds |
| `DISCORD_TOKEN` | ✅ | Bot token from Discord Developer Portal |
| `DISCORD_GUILD_ID` | ✅ | Your Discord server ID |
| `ADMIN_ROLE_NAME` | ✅ | Role name that can use admin commands |
| `SA_PASSWORD` | ✅ | SQL Server SA password (min 8 chars, mixed case + symbol) |
| `SQL_USER` | ✅ | SQL login username (typically `sa`) |
| `SQL_PASS` | ✅ | SQL login password |
| `RUN_HOUR` | ✅ | Hour (UTC, 0-23) to run daily. Default: `23` |
| `TILT_THRESHOLD` | ❌ | Consecutive losses for tilt alert. Default: `3` |
| `WEEKLY_DAY` | ❌ | Day name for weekly leaderboard. Default: `Sunday` |
| `MATCH_LIMIT` | ❌ | Recent matches to analyse per player. Default: `25` |

---

## 🗃️ Database Schema

| Table | Purpose |
|---|---|
| `Players` | Source of truth — one row per Discord user per race |
| `AllParticipants` | Last-known snapshot per player, used for daily MMR delta |
| `LadderHistory` | One row per player per day — powers the weekly leaderboard |
| `LadderStaging` | Scratch table rebuilt every run |
| `LeagueThresholds` | Editable MMR breakpoints per division — no code changes needed each season |
| `RunControl` | Drives the scheduler, force-run flag, and `/status` command |

All tables are created automatically on first boot. No manual SQL setup required.

---

## 🌐 Web Dashboard

The tracker generates a self-contained `index.html` after each run, served by the nginx container.

- **Direct access:** `http://your-host-ip:8090`
- **Via Traefik:** `https://ladder.yourdomain.com`

The page includes the full leaderboard, league badges, today's MMR changes, win rates, streak data, weekly standings, and any active alerts (ATH, tilt, league changes). It auto-refreshes every 5 minutes.

---

## 📡 Data Source

Player data is fetched from [SC2Pulse](https://sc2pulse.nephest.com/sc2/) — an open-source, community-maintained StarCraft II ladder tracker.

- **MMR & rank:** `/api/character/{id}/summary/1v1/7/{race}`
- **Match history:** `/api/group/match`
- **All-time peak:** `/api/character/{id}/summary/1v1/5000/{race}`

League MMR thresholds are for the **Americas** server, current season. Update them each new season using `/update-league` in Discord or by editing the `LeagueThresholds` table directly.

---

## 🔧 Updating

After modifying any script:

```bash
# If LadderTracker.ps1 or entrypoint.ps1 changed
docker build -t laddertracker-app:latest .

# If bot.py changed
docker build -t laddertracker-bot:latest ./bot
```

Then redeploy via Portainer or `docker compose up -d`.

For Git:

```bash
git add .
git commit -m "describe what changed"
git push
```

---

## 📜 License

MIT — do whatever you want with it.

---

<div align="center">
  <sub>Built for the Formless Bearsloths &bull; Powered by SC2Pulse &bull; Running on coffee and ladder anxiety</sub>
</div>
