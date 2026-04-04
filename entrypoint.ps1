<#
.SYNOPSIS
    Entrypoint for the LadderTracker Docker container.
.DESCRIPTION
    1. Waits for SQL Server to be ready.
    2. Bootstraps the database and all tables (idempotent - safe to re-run).
    3. Seeds LeagueThresholds with current Americas season data if empty.
    4. Runs a 60-second poll loop that handles both scheduled and force-triggered runs.
    5. Rotates logs older than 30 days on startup.
#>

$sqlInstance = $env:SQL_SERVER  ?? 'sqlserver'
$sqlUser     = $env:SQL_USER
$sqlPass     = $env:SQL_PASS
$runHour     = if ($env:RUN_HOUR) { [int]$env:RUN_HOUR } else { 23 }
$dbName      = 'FxB_LadderLeaderboard'
$dataRoot    = '/data'

$sqlMaster = @{ ServerInstance = $sqlInstance; Database = 'master'; Username = $sqlUser; Password = $sqlPass; Encrypt = 'Optional' }
$sqlApp    = @{ ServerInstance = $sqlInstance; Database = $dbName;  Username = $sqlUser; Password = $sqlPass; Encrypt = 'Optional' }

Write-Host "============================================"
Write-Host " LadderTracker Entrypoint"
Write-Host " SQL Server : $sqlInstance"
Write-Host " Run hour   : $runHour`:00 UTC daily"
Write-Host "============================================"

#region -- Wait for SQL Server --------------------------------------------------
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Waiting for SQL Server..."
$ready = $false
$attempts = 0
while (-not $ready -and $attempts -lt 36) {
    try {
        Invoke-Sqlcmd @sqlMaster -Query 'SELECT 1' -ErrorAction Stop | Out-Null
        $ready = $true
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] SQL Server is ready."
    } catch {
        $attempts++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Not ready ($attempts/36), retrying in 10s..."
        Start-Sleep -Seconds 10
    }
}
if (-not $ready) { Write-Error "SQL Server unavailable after 6 minutes."; exit 1 }
#endregion

#region -- Bootstrap Database ---------------------------------------------------
Invoke-Sqlcmd @sqlMaster -Query @"
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = '$dbName')
    CREATE DATABASE [$dbName];
"@
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database '$dbName' ready."
#endregion

#region -- Bootstrap Tables -----------------------------------------------------
Invoke-Sqlcmd @sqlApp -Query @"
-- Players: one row per Discord user per race.
-- LLID format: {discordId}_{Race}  e.g. 123456789_Zerg
IF OBJECT_ID('Players', 'U') IS NULL
    CREATE TABLE Players (
        LLID        VARCHAR(255) PRIMARY KEY,
        DiscordID   VARCHAR(255) NOT NULL,
        NephestID   INT          NOT NULL,
        Name        VARCHAR(255) NOT NULL,
        Race        VARCHAR(50)  NOT NULL,
        BattleTag   VARCHAR(255) NOT NULL,
        Region      VARCHAR(10)  NOT NULL DEFAULT 'US',
        Active      BIT          NOT NULL DEFAULT 1,
        AddedDate   DATETIME     NOT NULL DEFAULT GETDATE()
    );

-- AllParticipants: last-known snapshot per LLID for daily delta
IF OBJECT_ID('AllParticipants', 'U') IS NULL
    CREATE TABLE AllParticipants (
        LLID       VARCHAR(255) PRIMARY KEY,
        Name       VARCHAR(255),
        MMR        INT,
        Race       VARCHAR(255),
        Games      INT,
        NephestID  INT,
        MaxWS      INT,
        MaxLS      INT,
        RatingMax  INT,
        WinPercent VARCHAR(10)
    );

-- LadderHistory: one row per LLID per day for weekly leaderboard
IF OBJECT_ID('LadderHistory', 'U') IS NULL
    CREATE TABLE LadderHistory (
        ID         INT IDENTITY PRIMARY KEY,
        RunDate    DATE         NOT NULL DEFAULT CAST(GETDATE() AS DATE),
        LLID       VARCHAR(255),
        Name       VARCHAR(255),
        Race       VARCHAR(255),
        MMR        INT,
        Games      INT,
        MaxWS      INT,
        MaxLS      INT,
        RatingMax  INT,
        WinPercent VARCHAR(10)
    );

-- LadderStaging: scratch table rebuilt every run
IF OBJECT_ID('LadderStaging', 'U') IS NULL
    CREATE TABLE LadderStaging (
        Name       VARCHAR(255),
        Race       VARCHAR(255),
        MMR        INT,
        Games      INT,
        NephestID  INT,
        MaxWS      INT,
        MaxLS      INT,
        RatingMax  INT,
        LLID       VARCHAR(255) PRIMARY KEY,
        WinPercent VARCHAR(10)
    );

-- LeagueThresholds: MMR breakpoints per division - editable via /update-league
IF OBJECT_ID('LeagueThresholds', 'U') IS NULL
    CREATE TABLE LeagueThresholds (
        ID             INT IDENTITY PRIMARY KEY,
        LeagueName     VARCHAR(50) NOT NULL UNIQUE,
        ShortName      VARCHAR(50) NOT NULL,
        MinMMR         INT         NOT NULL,
        EmojiCodepoint INT         NOT NULL,
        EmbedColor     INT         NOT NULL,
        SortOrder      INT         NOT NULL
    );

-- RunControl: drives scheduling, force-run, and /status bot command
IF OBJECT_ID('RunControl', 'U') IS NULL
BEGIN
    CREATE TABLE RunControl (
        ID             INT PRIMARY KEY DEFAULT 1,
        ForceRun       BIT           NOT NULL DEFAULT 0,
        LastRunTime    DATETIME      NULL,
        LastRunStatus  VARCHAR(20)   NULL,
        LastRunPlayers INT           NULL,
        LastRunError   NVARCHAR(2000) NULL,
        RunHour        INT           NOT NULL DEFAULT 23
    );
    INSERT INTO RunControl (ID, ForceRun, RunHour) VALUES (1, 0, $runHour);
END
"@

# Always sync RunHour in case the env var changed between restarts
Invoke-Sqlcmd @sqlApp -Query "UPDATE RunControl SET RunHour = $runHour WHERE ID = 1;"

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Tables ready."
#endregion

#region -- Seed LeagueThresholds ------------------------------------------------
# Americas season thresholds. Only inserts if the table is empty so manual
# edits via /update-league are not overwritten on container restart.
Invoke-Sqlcmd @sqlApp -Query @"
IF NOT EXISTS (SELECT 1 FROM LeagueThresholds)
BEGIN
    -- EmojiCodepoint decimal values:
    --   128081 = 0x1F451 crown      (Grandmaster)
    --   128142 = 0x1F48E gem        (Master)
    --   128311 = 0x1F537 blue diam  (Diamond)
    --     9898 = 0x26AA  circle     (Platinum)
    --   129351 = 0x1F947 gold medal (Gold)
    --   129352 = 0x1F948 silv medal (Silver)
    --   129353 = 0x1F949 brnz medal (Bronze)
    --    10067 = 0x2753  question   (Unranked)
    INSERT INTO LeagueThresholds (LeagueName, ShortName, MinMMR, EmojiCodepoint, EmbedColor, SortOrder) VALUES
    ('Grandmaster', 'Grandmaster', 4800, 128081, 16766720, 20),
    ('Master 1',    'Master',      4674, 128142, 10973399, 19),
    ('Master 2',    'Master',      4548, 128142, 10973399, 18),
    ('Master 3',    'Master',      4421, 128142, 10973399, 17),
    ('Diamond 1',   'Diamond',     4260, 128311,  3447003, 16),
    ('Diamond 2',   'Diamond',     4098, 128311,  3447003, 15),
    ('Diamond 3',   'Diamond',     3937, 128311,  3447003, 14),
    ('Platinum 1',  'Platinum',    3858,   9898, 12895428, 13),
    ('Platinum 2',  'Platinum',    3780,   9898, 12895428, 12),
    ('Platinum 3',  'Platinum',    3701,   9898, 12895428, 11),
    ('Gold 1',      'Gold',        3578, 129351, 16766720, 10),
    ('Gold 2',      'Gold',        3455, 129351, 16766720,  9),
    ('Gold 3',      'Gold',        3332, 129351, 16766720,  8),
    ('Silver 1',    'Silver',      3216, 129352, 12303291,  7),
    ('Silver 2',    'Silver',      3100, 129352, 12303291,  6),
    ('Silver 3',    'Silver',      2984, 129352, 12303291,  5),
    ('Bronze 1',    'Bronze',      2656, 129353, 10824234,  4),
    ('Bronze 2',    'Bronze',      2328, 129353, 10824234,  3),
    ('Bronze 3',    'Bronze',      2000, 129353, 10824234,  2),
    ('Unranked',    'Unranked',       0,  10067,  9807270,  1);
    PRINT 'LeagueThresholds seeded.';
END
"@
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] League thresholds ready."
#endregion

#region -- Log Rotation ---------------------------------------------------------
$logDir = "$dataRoot/logs"
if (Test-Path $logDir) {
    $cutoff  = (Get-Date).AddDays(-30)
    $removed = Get-ChildItem "$logDir/*.txt" -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -lt $cutoff }
    if ($removed) {
        $removed | Remove-Item -Force
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Rotated $($removed.Count) log file(s) older than 30 days."
    }
}
#endregion

#region -- Poll Loop ------------------------------------------------------------
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Entering poll loop (checking every 60s)."

while ($true) {
    try {
        $control       = Invoke-Sqlcmd @sqlApp -Query "SELECT ForceRun, LastRunTime, RunHour FROM RunControl WHERE ID = 1"
        $now           = Get-Date
        $scheduledTime = Get-Date -Hour $runHour -Minute 0 -Second 0 -Millisecond 0

        $shouldRun = $false
        $reason    = ''

        # Priority 1: force-run flag set by /run bot command
        if ($control.ForceRun -eq $true) {
            Invoke-Sqlcmd @sqlApp -Query "UPDATE RunControl SET ForceRun = 0 WHERE ID = 1"
            $shouldRun = $true
            $reason    = 'manual trigger'
        }
        # Priority 2: within the 2-minute window of scheduled time and not yet run today
        elseif ($now -ge $scheduledTime -and $now -lt $scheduledTime.AddMinutes(2)) {
            $lastRun = if ($control.LastRunTime -is [DBNull] -or $null -eq $control.LastRunTime) {
                $null
            } else {
                [datetime]$control.LastRunTime
            }
            if ($null -eq $lastRun -or $lastRun.Date -lt $now.Date) {
                $shouldRun = $true
                $reason    = 'scheduled'
            }
        }

        if ($shouldRun) {
            Write-Host ""
            Write-Host "============================================"
            Write-Host " Run starting ($reason) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Write-Host "============================================"

            Invoke-Sqlcmd @sqlApp -Query @"
UPDATE RunControl
SET LastRunStatus = 'Running', LastRunTime = GETDATE(), LastRunError = NULL
WHERE ID = 1;
"@
            & /app/LadderTracker.ps1

            # Defensive update - LadderTracker.ps1 updates RunControl itself on
            # success/failure, but if it exits unexpectedly this catches it.
            if ($LASTEXITCODE -ne 0) {
                Invoke-Sqlcmd @sqlApp -Query @"
UPDATE RunControl
SET LastRunStatus = 'Failed', LastRunError = 'Script exited with code $LASTEXITCODE'
WHERE ID = 1 AND LastRunStatus = 'Running';
"@
            }

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Run finished (exit code: $LASTEXITCODE)."
        }
    } catch {
        Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Poll loop error: $_"
    }

    Start-Sleep -Seconds 60
}
#endregion
