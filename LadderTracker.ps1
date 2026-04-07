<#
.SYNOPSIS
    Queries SC2Pulse for StarCraft II ladder statistics.
.DESCRIPTION
    Runs inside Docker. Reads active players from the Players SQL table,
    fetches SC2Pulse data with retry logic, posts a single Discord embed,
    and updates RunControl with success/failure status.

    Required environment variables:
        DISCORD_WEBHOOK  - Full Discord webhook URL
        SQL_SERVER       - SQL Server hostname
        SQL_USER         - SQL login username
        SQL_PASS         - SQL login password

    Optional:
        TILT_THRESHOLD   - Consecutive losses to trigger tilt alert (default: 3)
        WEEKLY_DAY       - Day name for weekly leaderboard (default: Sunday)
        MATCH_LIMIT      - Recent matches to analyse per player (default: 25)
.LINK
    https://github.com/sc2-pulse | https://github.com/darinbolton/LadderTracker
#>

#region -- Configuration --------------------------------------------------------
$date          = Get-Date -Format 'MM-dd-yyyy'
$dayOfWeek     = (Get-Date).DayOfWeek.ToString()
$baseUrl       = 'https://sc2pulse.nephest.com/sc2/api'
$webhookUrl    = $env:DISCORD_WEBHOOK
$sqlInstance   = $env:SQL_SERVER  ?? 'sqlserver'
$sqlUser       = $env:SQL_USER
$sqlPass       = $env:SQL_PASS
$sqlDatabase   = 'FxB_LadderLeaderboard'
$matchLimit    = if ($env:MATCH_LIMIT)    { [int]$env:MATCH_LIMIT }    else { 25 }
$tiltThreshold = if ($env:TILT_THRESHOLD) { [int]$env:TILT_THRESHOLD } else { 3  }
$weeklyDay     = $env:WEEKLY_DAY ?? 'Sunday'
$dataRoot      = '/data'

$sqlParams = @{
    ServerInstance = $sqlInstance
    Database       = $sqlDatabase
    Username       = $sqlUser
    Password       = $sqlPass
    Encrypt        = 'Optional'
}

# Emoji as Unicode codepoints - encoding-safe
$eCrown      = [char]::ConvertFromUtf32(0x1F451)
$eDiamond    = [char]::ConvertFromUtf32(0x1F48E)
$eBlueDia    = [char]::ConvertFromUtf32(0x1F537)
$eCircle     = [char]0x26AA
$eGoldMedal  = [char]::ConvertFromUtf32(0x1F947)
$eSilverMed  = [char]::ConvertFromUtf32(0x1F948)
$eBronzeMed  = [char]::ConvertFromUtf32(0x1F949)
$eQuestion   = [char]0x2753
$eArrowUp    = [char]0x2B06
$eArrowDown  = [char]0x2B07
$eArrowRight = [char]0x27A1
$eTrophy     = [char]::ConvertFromUtf32(0x1F3C6)
$eParty      = [char]::ConvertFromUtf32(0x1F389)
$eFire       = [char]::ConvertFromUtf32(0x1F525)
$eBoom       = [char]::ConvertFromUtf32(0x1F4A5)
$eStar       = [char]::ConvertFromUtf32(0x1F31F)
$eWarning    = [char]0x26A0
$eRedDot     = [char]::ConvertFromUtf32(0x1F534)
$eSOS        = [char]::ConvertFromUtf32(0x1F198)
$eSiren      = [char]::ConvertFromUtf32(0x1F6A8)
$eWhiteFlag  = [char]::ConvertFromUtf32(0x1F3F3)
$eConfetti   = [char]::ConvertFromUtf32(0x1F38A)
$eMedal      = [char]::ConvertFromUtf32(0x1F3C5)
$eRocket     = [char]::ConvertFromUtf32(0x1F680)
$ePartyFace  = [char]::ConvertFromUtf32(0x1F973)
$eChartUp    = [char]::ConvertFromUtf32(0x1F4C8)
$eGrimace    = [char]::ConvertFromUtf32(0x1F62C)
$eSkull      = [char]::ConvertFromUtf32(0x1F480)
$eTombstone  = [char]::ConvertFromUtf32(0x1FAA6)
$eChartDown  = [char]::ConvertFromUtf32(0x1F4C9)
$eSad        = [char]::ConvertFromUtf32(0x1F614)
$eBarChart   = [char]::ConvertFromUtf32(0x1F4CA)
$eMailbox    = [char]::ConvertFromUtf32(0x1F4ED)
$eCross      = [char]::ConvertFromUtf32(0x274C)

@(
    "$dataRoot/logs",
    "$dataRoot/MMR/AllPartipants",
    "$dataRoot/MMR/DailyWinner",
    "$dataRoot/MMR/DailyLoser",
    "$dataRoot/SQLOutput"
) | ForEach-Object { if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ | Out-Null } }
#endregion

Start-Transcript -Path "$dataRoot/logs/logs-$date.txt" -Force

#region -- Helper: Get-League ---------------------------------------------------
# Loaded from SQL at runtime - no hardcoded thresholds in this script.
function Get-League ([int]$MMR) {
    $match = $script:leagueThresholds |
             Where-Object { $MMR -ge [int]$_.MinMMR } |
             Sort-Object { [int]$_.MinMMR } -Descending |
             Select-Object -First 1

    if (-not $match) {
        return [PSCustomObject]@{ Name = 'Unranked'; ShortName = 'Unranked'; Emoji = $eQuestion; Color = 9807270 }
    }

    $code  = [int]$match.EmojiCodepoint
    $emoji = if ($code -gt 0xFFFF) { [char]::ConvertFromUtf32($code) } else { [char]$code }

    return [PSCustomObject]@{
        Name      = $match.LeagueName
        ShortName = $match.ShortName
        Emoji     = $emoji
        Color     = [int]$match.EmbedColor
    }
}
#endregion

#region -- Helper: Discord ------------------------------------------------------
function Limit-String ([string]$Text, [int]$Max = 1024) {
    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + '...'
}

function Send-DiscordEmbed {
    param(
        [string]$WebhookUrl,
        [string]$Title,
        [string]$Description = '',
        [int]$Color = 5793266,
        [object[]]$Fields = @(),
        [string]$Footer = 'Crafted by Gale for the StarCraft II Community'
    )

    # Enforce Discord character limits
    $safeTitle  = Limit-String $Title       -Max 256
    $safeDesc   = Limit-String $Description -Max 4096

    # Build fields as PSCustomObjects - more reliable serialization than hashtables
    $safeFields = @(
        ($Fields | Where-Object { $null -ne $_ }) | ForEach-Object {
            [PSCustomObject]@{
                name   = Limit-String ([string]$_.name)  -Max 256
                value  = Limit-String ([string]$_.value) -Max 1024
                inline = [bool]$_.inline
            }
        }
    )

    # Total embed length guard
    $totalLen = $safeTitle.Length + $safeDesc.Length +
                ($safeFields | ForEach-Object { $_.name.Length + $_.value.Length } |
                 Measure-Object -Sum).Sum
    if ($totalLen -gt 6000) {
        $excess   = $totalLen - 5990
        $safeDesc = Limit-String $safeDesc -Max ([Math]::Max(100, $safeDesc.Length - $excess))
        Write-Warning "Discord embed truncated - was $totalLen chars."
    }

    # Build payload using PSCustomObject throughout for predictable ConvertTo-Json output
    $payload = [PSCustomObject]@{
        embeds = @(
            [PSCustomObject]@{
                title       = $safeTitle
                description = $safeDesc
                color       = [int]$Color
                fields      = $safeFields
                footer      = [PSCustomObject]@{ text = $Footer }
                timestamp   = (Get-Date -Format 'o')
            }
        )
    }

    $body = $payload | ConvertTo-Json -Depth 8
    Write-Verbose "Discord payload ($($body.Length) chars): $($body.Substring(0, [Math]::Min(300, $body.Length)))..." -Verbose

    do {
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body
            $retry = $false
        } catch {
            $response = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($response.retry_after) {
                $wait = ($response.retry_after + 0.5) * 1000
                Write-Verbose "Discord rate limited - waiting $($response.retry_after)s" -Verbose
                Start-Sleep -Milliseconds $wait
                $retry = $true
            } else { throw }
        }
    } while ($retry)
}

function Send-FailureEmbed {
    param([string]$ErrorMessage, [int]$PlayersProcessed = 0)
    if (-not $webhookUrl) { return }
    try {
        Send-DiscordEmbed -WebhookUrl $webhookUrl `
            -Title "$eCross LadderTracker Run Failed - $date" `
            -Description "An error occurred during the daily run. The report was not posted." `
            -Color 15548997 `
            -Fields @(
                @{ name = 'Error';              value = (Limit-String $ErrorMessage -Max 1024); inline = $false },
                @{ name = 'Players processed';  value = "$PlayersProcessed before failure";     inline = $true  }
            )
    } catch {
        Write-Warning "Could not post failure notification to Discord: $_"
    }
}
#endregion

#region -- Helper: SC2Pulse API with retry --------------------------------------
function Invoke-SC2PulseApi {
    param([string]$Uri, [int]$MaxRetries = 3)
    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 30 -ErrorAction Stop
        } catch {
            $attempt++
            if ($attempt -ge $MaxRetries) {
                Write-Warning "SC2Pulse permanently failed after $MaxRetries attempts: $Uri"
                throw
            }
            $delaySec = [Math]::Pow(2, $attempt)
            Write-Warning "SC2Pulse attempt $attempt/$MaxRetries failed, retrying in $($delaySec)s"
            Start-Sleep -Seconds $delaySec
        }
    }
}
#endregion

#region -- Helper: Message Pools ------------------------------------------------
function Get-WinnerMessage ([string]$Name, [int]$Change, [string]$Race) {
    $p = "``$Name``"
    $n = "``$Change``"

    if ($Change -eq 69) {
        return @(
            "$p gained $n MMR today... niiiiiiiiiiice. ;)",
            "$p gained exactly $n MMR. The gods of the ladder have spoken.",
            "Nice. $p gained $n MMR. We are legally required to acknowledge this.",
            "$p gained $n MMR. Did you plan that? Because respect if so.",
            "$p achieved the sacred number. $n MMR. We are not worthy."
        ) | Get-Random
    }

    $pools = @{
        175 = @{
            Generic = @(
                "$p ...Have you been smurfing? $n MMR gained today - absolutely staggering.",
                "$p just had one of the greatest ladder sessions in recorded SC2 history. $n MMR. Unreal.",
                "$p achieved a state of enlightenment today. $n MMR gained. We bow to you.",
                "$p found the exploit. $n MMR? Somebody call Blizzard.",
                "$p may have broken the ladder. $n MMR today - please report yourself.",
                "$p didn't play SC2 today, they played a completely different game. $n MMR is the evidence.",
                "Forensic scientists are analyzing $p's replay. $n MMR defies current understanding.",
                "$p entered god mode. $n MMR gained. No other explanation exists."
            )
            Zerg    = @(
                "The swarm consumed everything in its path. The debris was $n MMR.",
                "No opponent survived. The swarm provided.",
                "Every drone was a warrior today. $n MMR is the harvest."
            )
            Terran  = @(
                "Bio micro was operating at a superhuman level. $n MMR says so.",
                "Somewhere a Zerg is blaming imbalance. $n MMR disagrees.",
                "The army never died. Not once. $n MMR is proof."
            )
            Protoss = @(
                "En Taro Artanis. The golden armada left no survivors and $n MMR richer.",
                "The nexus was always charged. The results speak for themselves.",
                "Warp-in after warp-in, all of them winners. $n MMR."
            )
        }
        120 = @{
            Generic = @(
                "$p is gaining mo-fucking-mentum! Moved up $n MMR!",
                "$p is on an absolute tear. $n MMR and counting.",
                "$p is in the matrix right now. $n MMR gained.",
                "$p didn't ladder today - they harvested. $n MMR.",
                "$p has been fully unleashed. $n MMR gained today.",
                "$p is running hot. $n MMR gained - don't touch them right now.",
                "$p is currently untouchable on the ladder. $n MMR today."
            )
            Zerg    = @(
                "Inject discipline: perfect. $n MMR: also perfect.",
                "The macro Zerg experience, fully executed. $n MMR.",
                "Creep spread, swarm spread, MMR spread. $n of it."
            )
            Terran  = @(
                "Someone has been watching Maru VODs. It shows. $n MMR.",
                "The micro was at Terran god levels today. $n MMR.",
                "Every drop landed. Every push timed. $n MMR."
            )
            Protoss = @(
                "ForGG arc activated. Macro Toss fully online. $n MMR.",
                "Colossus, carriers, and chaos. $n MMR.",
                "The storms were landing and the army kept flying. $n MMR."
            )
        }
        100 = @{
            Generic = @(
                "$p learned a new build - $n MMR gained today!",
                "$p is in the zone. $n MMR - someone's been watching VODs.",
                "$p went absolutely off today. $n MMR? Get it!",
                "$p just had themselves a day. $n MMR gained.",
                "$p is built different. $n MMR in a single session.",
                "$p unlocked something today. $n MMR is just the beginning.",
                "$p's mechanics are peaking. $n MMR today."
            )
            Zerg    = @(
                "Every larva was accounted for. $n MMR too.",
                "The roach-ravager comp was never stopped. $n MMR.",
                "Nydus into their main. $n MMR out."
            )
            Terran  = @(
                "The bunker held every time today. $n MMR is proof.",
                "Bio + medivacs, no notes. $n MMR.",
                "Every scan found something worth attacking. $n MMR."
            )
            Protoss = @(
                "The storms were landing. All of them. $n MMR.",
                "Warpgate was never on cooldown. Somehow. $n MMR.",
                "The charge hit first, every time. $n MMR."
            )
        }
        75 = @{
            Generic = @(
                "$p ...KILLING SPREE! Feasted on the ladder today, gaining $n MMR!",
                "$p was absolutely slapping today. $n MMR gained.",
                "$p said 'not today' to every single opponent. $n MMR!",
                "$p woke up and chose violence. $n MMR.",
                "$p showed up today and the ladder noticed. $n MMR.",
                "$p entered a flow state and the opponents paid for it. $n MMR.",
                "$p had the hands today. $n MMR as proof.",
                "$p is currently a menace on the ladder. $n MMR today."
            )
            Zerg    = @(
                "Ling-bane-hydra hit like a freight train. $n MMR.",
                "Drone first, army second, MMR always. $n MMR.",
                "The bane connect was perfect. Every time. $n MMR."
            )
            Terran  = @(
                "Stim was up when it mattered. Every time. $n MMR.",
                "Drop harass enabled. Economy destroyed. $n MMR.",
                "The Hellion run-by found workers. Many workers. $n MMR."
            )
            Protoss = @(
                "The blink stalkers blinked forward today. $n MMR.",
                "The chargelot runby found a home today. $n MMR.",
                "Skytoss transition complete. Resistance futile. $n MMR."
            )
        }
        50 = @{
            Generic = @(
                "$p gained a respectable $n MMR today!",
                "$p had a great session - up $n MMR.",
                "$p is cooking. $n MMR today.",
                "$p found their groove - $n MMR gained!",
                "$p had a clean session. $n MMR up, no drama.",
                "$p climbed $n MMR today. Consistent and steady.",
                "$p is building momentum. $n MMR today."
            )
            Zerg    = @(
                "The creep spread. The MMR followed. $n MMR.",
                "Overlord scouts paid dividends today. $n MMR.",
                "Every hatchery was full. So is the MMR tally. $n."
            )
            Terran  = @(
                "Factory into bio into win. $n MMR.",
                "Mule efficiency was exceptional today. $n MMR.",
                "The push timed perfectly into their natural. $n MMR."
            )
            Protoss = @(
                "Gate-expand-expand and it worked. $n MMR.",
                "The immortal-sentry push was clean. $n MMR.",
                "The phoenix lifted SCVs. The MMR lifted too. $n."
            )
        }
        25 = @{
            Generic = @(
                "$p had a solid session, gaining $n MMR today!",
                "$p put in some work - up $n MMR!",
                "$p is making progress. $n MMR in the bag.",
                "$p climbed $n MMR. The grind is real.",
                "$p is trending in the right direction. $n MMR today.",
                "$p is chipping away. $n MMR closer to the dream.",
                "$p is steady and moving up. $n MMR gained."
            )
            Zerg    = @(
                "The swarm grows stronger. $n MMR at a time.",
                "Hatchery count: up. MMR count: also up. $n.",
                "The queen's inject kept the momentum going. $n MMR."
            )
            Terran  = @(
                "The barracks was always producing. $n MMR.",
                "Orbital command scanned and found $n MMR.",
                "Supply was never blocked. Neither was success. $n MMR."
            )
            Protoss = @(
                "Nexus charged, Protoss won. $n MMR.",
                "The gateway units held their ground. $n MMR.",
                "Chrono boost went to the right building. $n MMR."
            )
        }
        1 = @{
            Generic = @(
                "$p gained a little MMR, or just sucked less than everyone else. They moved up $n MMR today!",
                "$p inched forward $n MMR. Every point counts. Allegedly.",
                "$p moved up $n MMR. Not much, but it's honest work.",
                "$p technically improved today. $n MMR says so.",
                "$p scraped together $n MMR. We'll take it.",
                "$p is making micro-progress. $n MMR. Emphasis on micro.",
                "A win is a win. $p netted $n MMR today and we're not asking questions.",
                "$p gained $n MMR. The margin of victory was small. It still counts."
            )
            Zerg    = @(
                "Even one larva makes a difference. So does $n MMR.",
                "The queen walked so the drone could drone. $n MMR.",
                "Slow and steady. $n MMR."
            )
            Terran  = @(
                "One Marine survived. One win secured. $n MMR.",
                "The SCV kept building. $n MMR reward.",
                "Barely scraped through, but the ladder gave $n MMR anyway."
            )
            Protoss = @(
                "Even a single zealot can turn the tide. Barely. $n MMR.",
                "The nexus overcharged for exactly $n MMR. Worth it.",
                "The mothership core provided. Barely. $n MMR."
            )
        }
    }

    $tier = switch ($Change) {
        { $_ -gt 175 } { 175; break }
        { $_ -gt 120 } { 120; break }
        { $_ -gt 100 } { 100; break }
        { $_ -gt  75 } { 75;  break }
        { $_ -gt  50 } { 50;  break }
        { $_ -gt  25 } { 25;  break }
        default         { 1 }
    }

    $pool = $pools[$tier].Generic
    if ($pools[$tier].ContainsKey($Race)) { $pool += $pools[$tier][$Race] }
    return ($pool | Get-Random)
}

function Get-LoserMessage ([string]$Name, [int]$Change, [string]$Race) {
    $abs = [Math]::Abs($Change)
    $p   = "``$Name``"
    $n   = "``$abs``"

    $pools = @{
        200 = @{
            Generic = @(
                "$p ...Is this a Barcode moment? Please stop. Get some help. $n MMR lost today - absolutely staggering.",
                "$p lost $n MMR today. The forensic scientists are still reconstructing what happened.",
                "$p dropped $n MMR. We contacted Blizzard. They said 'lmao'.",
                "$p lost $n MMR today. We don't have the words. No one does.",
                "$p fed the ladder $n MMR. They are now its primary source of sustenance.",
                "$p lost $n MMR. The Geneva Convention does not cover what happened to their account today.",
                "$p lost $n MMR. This is no longer a ladder session. This is a crime scene.",
                "$p lost $n MMR. A moment of silence for what was, and what could have been."
            )
            Zerg    = @(
                "Not enough drones. There were never enough drones. $n MMR gone.",
                "The swarm was hungry today, but not for wins. $n MMR.",
                "Every inject was a sorrow. Every engage a mistake. $n MMR."
            )
            Terran  = @(
                "The bio melted and so did the MMR. All $n of it.",
                "Supply blocked, pushed anyway, lost $n MMR. Heroic, in the worst way.",
                "The mech was slow. The losses were fast. $n MMR."
            )
            Protoss = @(
                "Forged in the celestial forge, lost $n MMR in Silver league.",
                "The mothership has left the building, taking $n MMR with it.",
                "En Taro Artanis. Artanis cannot help you now. $n MMR gone."
            )
        }
        150 = @{
            Generic = @(
                "$p ...Alright. Time to quit. Cut losses, pack it up, try another day. $n MMR lost - brutal.",
                "$p lost $n MMR. This is a cry for help and we're listening.",
                "$p dropped $n MMR today. Their keyboard has filed a restraining order.",
                "$p lost $n MMR. The session should have ended several games ago.",
                "$p bled $n MMR today. Log. Off. Now.",
                "$p lost $n MMR. At some point persistence becomes a disorder.",
                "$p's session outlasted their skill by about $n MMR.",
                "$p dropped $n MMR. The tilt was visible from space."
            )
            Zerg    = @(
                "Lost count of larva. Lost count of games. Lost $n MMR.",
                "The swarm faltered at $n MMR. Even nature has bad days.",
                "Banelings walked into their own mineral line. $n MMR."
            )
            Terran  = @(
                "Ran out of Mules before running out of problems. $n MMR gone.",
                "The push was timed. The timing was wrong. $n MMR.",
                "The ghost called an EMP on their own bio. $n MMR."
            )
            Protoss = @(
                "The immortal died first. The MMR died second. $n of it.",
                "Too many gate units, not enough wins. $n MMR down.",
                "The colossus walked off a cliff somehow. $n MMR."
            )
        }
        100 = @{
            Generic = @(
                "$p is donating MMR to the ladder. First come, first serve! $n MMR today.",
                "$p gave away $n MMR today - absolute philanthropy.",
                "$p lost $n MMR. That's not a bad day, that's a bad *decision* to keep playing.",
                "$p dropped $n MMR today. We are staging an intervention.",
                "$p lost $n MMR. At some point the matchmaker becomes the match*breaker*.",
                "At $n MMR lost, $p has officially entered the 'why am I still doing this' zone.",
                "$p lost $n MMR. The ladder took it personally."
            )
            Zerg    = @(
                "Roach-ravager into a wall. Repeatedly. $n MMR.",
                "The spine crawler wasn't enough. Neither was anything else. $n MMR.",
                "The overlord spotted the attack. The response came too late. $n MMR."
            )
            Terran  = @(
                "The ghost was never built. The nuke was never called. $n MMR lost.",
                "The tank never sieged in time. $n MMR.",
                "The marine split was not performed. The banelings were very happy. $n MMR."
            )
            Protoss = @(
                "The storm hit. It hit $p's own units. $n MMR.",
                "The blink was on cooldown every single time. $n MMR.",
                "The colossus was left at home. The enemy was not. $n MMR."
            )
        }
        75 = @{
            Generic = @(
                "$p ...Your MMR is in another castle. $n MMR lost today.",
                "$p lost $n MMR. That's a lot of cheese going unanswered.",
                "$p didn't have it today. $n MMR in the red.",
                "$p let the ladder bully them today. Down $n MMR.",
                "$p lost $n MMR. The ladder remembers. The ladder always remembers.",
                "$p and the ladder had a disagreement. The ladder won by $n MMR.",
                "The matchmaker was not kind today. $n MMR taken.",
                "$p lost $n MMR. Some days the game just isn't the game."
            )
            Zerg    = @(
                "Every inject was late. Every engage was wrong. $n MMR.",
                "The lings died to a wall-in. Again. $n MMR.",
                "The muta flock ran directly into marines. All of them. $n MMR."
            )
            Terran  = @(
                "Stim was on cooldown when it mattered most. $n MMR.",
                "The drop was sniped before it landed. $n MMR.",
                "The SCV pulled. The army panicked. $n MMR."
            )
            Protoss = @(
                "The carrier fleet arrived too late. $n MMR.",
                "The observer didn't see the attack coming. $n MMR surprise.",
                "The nexus tried to overcharge. The nexus was destroyed first. $n MMR."
            )
        }
        50 = @{
            Generic = @(
                "$p probably forgot their coffee today - down $n MMR.",
                "$p rage-queued their way to $n MMR lost.",
                "$p played $n MMR worth of bad games. Log off. Sleep. Try again.",
                "$p lost $n MMR today. We've all been there. We don't talk about those days.",
                "$p dropped $n MMR. Tomorrow is a new day, hopefully.",
                "$p lost $n MMR. The session had a rough third act.",
                "$p gave $n MMR back to the ladder. Generous."
            )
            Zerg    = @(
                "The inject was missed. The game was lost. $n MMR.",
                "The creep didn't spread. Neither did the wins. $n MMR.",
                "The roach speed upgrade was forgotten. $n MMR remembered."
            )
            Terran  = @(
                "The bunker didn't save them. The bunker never saves them. $n MMR.",
                "The SCV pull came too late. $n MMR.",
                "The medivac ran out of energy at the worst moment. $n MMR."
            )
            Protoss = @(
                "The warpgate was on cooldown at the worst time. $n MMR.",
                "The sentry ran out of energy before the problems ran out. $n MMR.",
                "The stalker tried to blink. The stalker failed to blink. $n MMR."
            )
        }
        0 = @{
            Generic = @(
                "$p played a few games that didn't go their way, moving down $n MMR today.",
                "$p is just redistributing MMR across the ladder. $n donated today.",
                "$p took an L today. Down $n MMR. Tomorrow's another day.",
                "$p donated $n MMR to the community. Generous soul.",
                "$p had a rough one. Down $n MMR. It happens.",
                "$p is just keeping the ladder economy healthy. $n MMR at a time.",
                "A minor setback for $p. Just $n MMR. We'll be fine.",
                "$p lost $n MMR. A hiccup. Nothing more. Probably."
            )
            Zerg    = @(
                "Even the swarm stumbles sometimes. $n MMR.",
                "One bad engage, $n MMR gone. It happens.",
                "The drone ratio was off. $n MMR off."
            )
            Terran  = @(
                "One bad drop, $n MMR. The marine died for nothing.",
                "The SCV didn't pull. Close game though. $n MMR.",
                "The bunker was half-built. $n MMR half-lost."
            )
            Protoss = @(
                "The nexus charged for nothing. $n MMR.",
                "The gateway units melted faster than expected. $n MMR.",
                "The warp prism dropped into static defense. $n MMR."
            )
        }
    }

    $tier = switch ($Change) {
        { $_ -lt -200 } { 200; break }
        { $_ -lt -150 } { 150; break }
        { $_ -lt -100 } { 100; break }
        { $_ -lt  -75 } { 75;  break }
        { $_ -lt  -50 } { 50;  break }
        default          { 0 }
    }

    $pool = $pools[$tier].Generic
    if ($pools[$tier].ContainsKey($Race)) { $pool += $pools[$tier][$Race] }
    return ($pool | Get-Random)
}

function Get-ATHMessage ([string]$Name, [int]$MMR, [string]$Race) {
    $p = "``$Name``"; $m = "``$MMR``"; $r = "``$Race``"
    $suffix = switch ($Race) {
        'ZERG'    { ' The swarm has never been stronger.' }
        'TERRAN'  { ' Long live the Marine.' }
        'PROTOSS' { ' En Taro Artanis.' }
        'RANDOM'  { ' Chaos reigns supreme.' }
        default   { '' }
    }
    return @(
        "$eTrophy **NEW $r ALL-TIME HIGH!** $p just peaked at $m MMR - a personal best for this race!$suffix",
        "$eCrown **PEAK $r MMR ACHIEVED!** $p has never been this high on $r`: $m MMR!$suffix",
        "$eParty $p just broke their $r personal record! $m MMR - new all-time high!$suffix",
        "$eFire **$r ATH UNLOCKED:** $p is playing the best $r SC2 of their life. $m MMR.$suffix",
        "$eBoom $p hit a new $r ceiling: $m MMR. Personal record shattered!$suffix",
        "$eStar Historic $r session from $p. $m MMR - that's a new career high for this race.$suffix"
    ) | Get-Random
}

function Get-TiltMessage ([string]$Name, [int]$Streak) {
    $p = "``$Name``"; $s = "``$Streak``"
    return @(
        "$eWarning **Tilt Alert:** $p has lost their last $s games in a row. Someone check on them.",
        "$eRedDot **Tilt Alert:** $p is on a $s-game losing streak. The ladder is undefeated.",
        "$eSOS **Tilt Alert:** $p has lost $s straight. If anyone sees them queue again, please intervene.",
        "$eWarning **Tilt Alert:** $p is $s losses deep with no signs of stopping. Send help.",
        "$eSiren **Tilt Alert:** We've lost $p to a $s-game skid. They were good people.",
        "$eWhiteFlag **Tilt Alert:** $p's last $s games have all been losses. The white flag has been spiritually raised."
    ) | Get-Random
}

function Get-PromotionMessage ([string]$Name, [string]$League, [string]$Emoji) {
    $p = "``$Name``"
    return @(
        "$eConfetti $p has been PROMOTED to **$League** $Emoji! Congratulations!",
        "$eArrowUp $p just hit **$League** $Emoji! The grind pays off!",
        "$eMedal $p climbed into **$League** $Emoji today - let's go!",
        "$eRocket $p just entered **$League** $Emoji. The ladder better watch out.",
        "$ePartyFace **PROMOTION!** $p has ascended to **$League** $Emoji. Hard work rewarded.",
        "$eChartUp $p is moving on up - **$League** $Emoji unlocked!"
    ) | Get-Random
}

function Get-DemotionMessage ([string]$Name, [string]$League, [string]$Emoji) {
    $p = "``$Name``"
    return @(
        "$eGrimace $p has been demoted to **$League** $Emoji. Just a temporary setback. Probably.",
        "$eArrowDown $p dropped to **$League** $Emoji. The road back starts now.",
        "$eSkull $p fell to **$League** $Emoji today. Bounce back SZN incoming.",
        "$eTombstone $p was sent back to **$League** $Emoji. The ladder is humbling.",
        "$eChartDown **DEMOTION.** $p has been relocated to **$League** $Emoji. We believe in the comeback.",
        "$eSad $p dropped to **$League** $Emoji. We'll light a candle."
    ) | Get-Random
}
#endregion

# ── Main execution wrapped in try/catch ──────────────────────────────────────
$processedCount = 0
try {

#region -- Load League Thresholds from SQL --------------------------------------
$script:leagueThresholds = @(Invoke-Sqlcmd @sqlParams -Query "SELECT * FROM LeagueThresholds ORDER BY MinMMR DESC")
Write-Verbose "Loaded $($script:leagueThresholds.Count) league thresholds from SQL." -Verbose
#endregion

#region -- SQL: Ensure tables exist (idempotent) --------------------------------
Invoke-Sqlcmd @sqlParams -Query @"
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
"@
#endregion

#region -- Data Collection ------------------------------------------------------
$playerRows = @(Invoke-Sqlcmd @sqlParams -Query @"
SELECT LLID, NephestID, Race, Region FROM Players WHERE Active = 1;
"@)

if ($playerRows.Count -eq 0) {
    Write-Warning "No active players in Players table. Have players register with /register."
    Invoke-Sqlcmd @sqlParams -Query @"
UPDATE RunControl SET LastRunStatus = 'Success', LastRunPlayers = 0 WHERE ID = 1;
"@
    Stop-Transcript
    exit 0
}

$apiResponses   = [System.Collections.Generic.List[PSCustomObject]]::new()
$skippedPlayers = [System.Collections.Generic.List[string]]::new()

foreach ($row in $playerRows) {
    $NephestID = $row.NephestID
    $race      = $row.Race.ToUpper()
    $region    = if ($row.Region) { $row.Region } else { 'US' }
    $llid      = $row.LLID

    try {
        $mmr = Invoke-SC2PulseApi "$baseUrl/character/$NephestID/summary/1v1/7/$race"

        # Skip players with no recent activity - null ratingLast means 0 games in 7 days
        if ($null -eq $mmr.ratingLast) {
            try { $skipName = (Invoke-SC2PulseApi "$baseUrl/character/$NephestID").name.Split('#')[0] }
            catch { $skipName = $llid }
            Write-Warning "[$llid] No activity in last 7 days, skipping."
            $skippedPlayers.Add("$skipName ($race) - no games in 7 days")
            continue
        }

        $nameTrimmed = (Invoke-SC2PulseApi "$baseUrl/character/$NephestID").name.Split('#')[0]
        $totalGames  = ((Invoke-SC2PulseApi "$baseUrl/character/$NephestID/summary/1v1/7").Games | Measure-Object -Sum).Sum
        $athMMR      = (Invoke-SC2PulseApi "$baseUrl/character/$NephestID/summary/1v1/5000/$race").RatingMax

        $fullMatchResponse = Invoke-SC2PulseApi "$baseUrl/group/match?typeCursor=_1V1&mapCursor=0&regionCursor=$region&type=_1V1&limit=$matchLimit&characterId=$NephestID"

        $last25 = $fullMatchResponse.Participants.Participant |
            Select-Object playercharacterid, decision, ratingchange |
            Where-Object { $_.PlayerCharacterID -eq $NephestID }

        $winPercent = (($last25 | Where-Object { $_.decision -eq 'WIN' }).Count / $matchLimit).ToString('P')

        $winStreak = $currentWS = 0
        foreach ($match in $last25) {
            if ($match.decision -eq 'WIN') { $currentWS++; if ($currentWS -gt $winStreak) { $winStreak = $currentWS } }
            else { $currentWS = 0 }
        }

        $lossStreak = $currentLS = 0
        foreach ($match in $last25) {
            if ($match.decision -eq 'LOSS') { $currentLS++; if ($currentLS -gt $lossStreak) { $lossStreak = $currentLS } }
            else { $currentLS = 0 }
        }

        $tiltStreak = 0
        foreach ($match in $last25) {
            if ($match.decision -eq 'LOSS') { $tiltStreak++ } else { break }
        }

        Write-Verbose "[$nameTrimmed | $race] MMR: $($mmr.ratingLast) | ATH: $athMMR | Tilt: $tiltStreak" -Verbose

        $apiResponses.Add([PSCustomObject]@{
            Name       = $nameTrimmed
            Race       = $race
            MMR        = $mmr.ratingLast
            Games      = $totalGames
            NephestID  = $NephestID
            MaxWS      = $winStreak
            MaxLS      = $lossStreak
            RatingMax  = $athMMR
            LLID       = $llid
            WinPercent = $winPercent
            NewATH     = ($mmr.ratingLast -ge $athMMR)
            TiltStreak = $tiltStreak
        })

        $processedCount++

    } catch {
        Write-Warning "[$llid] Failed after retries, skipping: $_"
        $skippedPlayers.Add("$llid - API error")
    }
}
#endregion

#region -- CSV Export (debug backup) --------------------------------------------
$sqlColumns = 'Name','Race','MMR','Games','NephestID','MaxWS','MaxLS','RatingMax','LLID','WinPercent'
$apiResponses | Select-Object $sqlColumns |
    Export-Csv -Path "$dataRoot/MMR/AllPartipants/$date.csv" -NoTypeInformation
#endregion

#region -- SQL: Populate Staging via Write-SqlTableData -------------------------
Invoke-Sqlcmd @sqlParams -Query 'TRUNCATE TABLE LadderStaging;'

if ($apiResponses.Count -gt 0) {
    $dt = [System.Data.DataTable]::new()
    $dt.Columns.Add('Name',       [string]) | Out-Null
    $dt.Columns.Add('Race',       [string]) | Out-Null
    $dt.Columns.Add('MMR',        [int])    | Out-Null
    $dt.Columns.Add('Games',      [int])    | Out-Null
    $dt.Columns.Add('NephestID',  [int])    | Out-Null
    $dt.Columns.Add('MaxWS',      [int])    | Out-Null
    $dt.Columns.Add('MaxLS',      [int])    | Out-Null
    $dt.Columns.Add('RatingMax',  [int])    | Out-Null
    $dt.Columns.Add('LLID',       [string]) | Out-Null
    $dt.Columns.Add('WinPercent', [string]) | Out-Null

    foreach ($r in $apiResponses) {
        $dr = $dt.NewRow()
        $dr['Name']       = $r.Name
        $dr['Race']       = $r.Race
        $dr['MMR']        = $r.MMR
        $dr['Games']      = $r.Games
        $dr['NephestID']  = $r.NephestID
        $dr['MaxWS']      = $r.MaxWS
        $dr['MaxLS']      = $r.MaxLS
        $dr['RatingMax']  = $r.RatingMax
        $dr['LLID']       = $r.LLID
        $dr['WinPercent'] = $r.WinPercent
        $dt.Rows.Add($dr)
    }

    Write-SqlTableData -ServerInstance $sqlInstance -DatabaseName $sqlDatabase -SchemaName 'dbo' `
        -TableName 'LadderStaging' -InputData $dt `
        -Credential (New-Object System.Management.Automation.PSCredential($sqlUser, (ConvertTo-SecureString $sqlPass -AsPlainText -Force)))
}
#endregion

#region -- SQL: Insert New Players ----------------------------------------------
Invoke-Sqlcmd @sqlParams -Query @"
INSERT INTO AllParticipants (LLID, Name, MMR, Race, Games, NephestID, MaxWS, MaxLS, RatingMax, WinPercent)
SELECT ls.LLID, ls.Name, ls.MMR, ls.Race, ls.Games, ls.NephestID, ls.MaxWS, ls.MaxLS, ls.RatingMax, ls.WinPercent
FROM LadderStaging ls
LEFT JOIN AllParticipants ap ON ls.LLID = ap.LLID
WHERE ap.LLID IS NULL;
"@
#endregion

#region -- SQL: Daily Delta -----------------------------------------------------
$playedOnly = @((Invoke-Sqlcmd @sqlParams -Query @"
SELECT
    LS.Name,
    LS.Race,
    LS.MMR,
    APS.MMR          AS PrevMMR,
    LS.MMR - APS.MMR AS Change,
    LS.MaxWS,
    LS.MaxLS,
    LS.RatingMax,
    LS.WinPercent,
    LS.LLID
FROM LadderStaging LS
FULL OUTER JOIN AllParticipants APS ON LS.LLID = APS.LLID
WHERE LS.MMR IS NOT NULL AND APS.MMR IS NOT NULL AND LS.MMR <> APS.MMR;
"@) | Select-Object Name, Race, MMR, PrevMMR, Change, MaxWS, MaxLS, RatingMax, WinPercent, LLID |
     Sort-Object -Property Change -Descending)

$playedOnly | Export-Csv -Path "$dataRoot/SQLOutput/AllParticipants.csv" -NoTypeInformation
#endregion

#region -- SQL: History Snapshot ------------------------------------------------
Invoke-Sqlcmd @sqlParams -Query @"
INSERT INTO LadderHistory (RunDate, LLID, Name, Race, MMR, Games, MaxWS, MaxLS, RatingMax, WinPercent)
SELECT CAST(GETDATE() AS DATE), ls.LLID, ls.Name, ls.Race, ls.MMR, ls.Games,
       ls.MaxWS, ls.MaxLS, ls.RatingMax, ls.WinPercent
FROM LadderStaging ls
WHERE NOT EXISTS (
    SELECT 1 FROM LadderHistory lh
    WHERE lh.LLID = ls.LLID AND lh.RunDate = CAST(GETDATE() AS DATE)
);
"@
#endregion

#region -- SQL: Update AllParticipants ------------------------------------------
Invoke-Sqlcmd @sqlParams -Query @"
UPDATE ap
SET ap.Name       = ls.Name,
    ap.MMR        = ls.MMR,
    ap.Games      = ls.Games,
    ap.MaxWS      = ls.MaxWS,
    ap.MaxLS      = ls.MaxLS,
    ap.RatingMax  = ls.RatingMax,
    ap.WinPercent = ls.WinPercent
FROM AllParticipants ap
JOIN LadderStaging ls ON ap.LLID = ls.LLID;
"@
#endregion

#region -- Discord: Build and Send Daily Embeds ---------------------------------

# ── Message 1: Plain text table (all tracked players, matches old script format)
$allTracked = @(Invoke-Sqlcmd @sqlParams -Query @"
SELECT
    ap.Name,
    ap.Race,
    ap.MMR,
    ap.WinPercent,
    ap.MaxWS,
    ap.MaxLS,
    ap.RatingMax,
    COALESCE(ls.MMR, ap.MMR)       AS CurrentMMR,
    ap.MMR                          AS PrevMMR,
    COALESCE(ls.MMR - ap.MMR, 0)   AS Change
FROM AllParticipants ap
LEFT JOIN LadderStaging ls ON ap.LLID = ls.LLID
ORDER BY COALESCE(ls.MMR, ap.MMR) DESC;
"@)

if ($allTracked.Count -gt 0) {
    # Slim column set - keeps the table narrow enough to fit Discord's embed width
    $header  = '{0,-15} {1,-8} {2,-5} {3,-7} {4,-6} {5,-5}' -f `
               'Player','Race','MMR','Change','Win%','Peak'
    $divider = '-' * 50

    $rows = $allTracked | ForEach-Object {
        $changeStr = if ([int]$_.Change -gt 0)     { "+$($_.Change)" } `
                     elseif ([int]$_.Change -lt 0) { "$($_.Change)"  } `
                     else                           { '-'             }
        $name    = [string]$_.Name
        $name    = if ($name.Length -gt 14) { $name.Substring(0,13) + '~' } else { $name }
        $race    = ([string]$_.Race).Substring(0, [Math]::Min(7, ([string]$_.Race).Length))
        $mmr     = [string]$_.CurrentMMR
        $winPct  = ([string]$_.WinPercent).Replace(' ','').Replace('%','') + '%'
        $peak    = if ($_.RatingMax -is [DBNull] -or $null -eq $_.RatingMax) { 'N/A' } else { [string]$_.RatingMax }

        '{0,-15} {1,-8} {2,-5} {3,-7} {4,-6} {5,-5}' -f `
            $name, $race, $mmr, $changeStr, $winPct, $peak
    }

    # Triple backticks must be on their own lines for Discord to render the code block
    $tableText  = '```' + "`n$header`n$divider`n" + ($rows -join "`n") + "`n" + '```'
    $netChange  = ($allTracked | Measure-Object -Property Change -Sum).Sum
    $boardColor = if ([int]$netChange -ge 0) { 5763719 } else { 15548997 }

    Send-DiscordEmbed -WebhookUrl $webhookUrl `
        -Title "$eBarChart Daily Ladder Report - $date" `
        -Description $tableText `
        -Color $boardColor
} else {
    Send-DiscordEmbed -WebhookUrl $webhookUrl `
        -Title "$eBarChart Daily Ladder Report - $date" `
        -Description "No players tracked yet. Have players register with /register." `
        -Color 9807270
}

Start-Sleep -Milliseconds 500

# ── Embed 2: Flavor text (gainer, loser, ATH, tilt, league changes, weekly) ──
$embedFields  = [System.Collections.Generic.List[object]]::new()
$flavorColor  = 9807270   # default grey - overridden below if players played today

if ($playedOnly.Count -gt 0) {
    $winner     = $playedOnly[0]
    $loser      = $playedOnly | Select-Object -Last 1
    $winChange  = [int]$winner.Change
    $lossChange = [int]$loser.Change

    $winnerMsg = if ($winChange -gt 0) {
        Get-WinnerMessage -Name $winner.Name -Change $winChange -Race $winner.Race
    } else {
        "``$($winner.Name)`` had the least painful session today, only losing ``$([Math]::Abs($winChange))`` MMR. A pyrrhic victory."
    }

    $loserMsg = if ($lossChange -lt 0) {
        Get-LoserMessage -Name $loser.Name -Change $lossChange -Race $loser.Race
    } else {
        "``$($loser.Name)`` made forward progress, but not as much as everyone else - up ``$lossChange`` MMR today!"
    }

    $winnerMsg | Out-File -Encoding utf8 "$dataRoot/MMR/DailyWinner/winner_$date.txt"
    $loserMsg  | Out-File -Encoding utf8 "$dataRoot/MMR/DailyLoser/bigLoser_$date.txt"

    $embedFields.Add(@{ name = "$eTrophy Biggest Gainer"; value = $winnerMsg; inline = $false })
    $embedFields.Add(@{ name = "$eSkull Biggest Loser";   value = $loserMsg;  inline = $false })
    $flavorColor = if ([int]($playedOnly | Measure-Object -Property Change -Sum).Sum -ge 0) { 5763719 } else { 15548997 }
} else {
    $flavorColor = 9807270
}

# Skipped players - show Name (Race) instead of raw LLID
if ($skippedPlayers.Count -gt 0) {
    $skipText = $skippedPlayers -join "`n"
    $embedFields.Add(@{ name = "$eWarning Skipped ($($skippedPlayers.Count))"; value = $skipText; inline = $false })
}

# ATH alerts
$athLines = @($apiResponses | Where-Object { $_.NewATH } | ForEach-Object {
    Get-ATHMessage -Name $_.Name -MMR $_.MMR -Race $_.Race
})
if ($athLines.Count -gt 0) {
    $embedFields.Add(@{ name = "$eTrophy New All-Time Highs"; value = ($athLines -join "`n"); inline = $false })
}

# Tilt alerts - deduplicate by player name so multi-race players only appear once,
# using the highest tilt streak across all their registrations
$tiltLines = @(
    $apiResponses |
    Where-Object { $_.TiltStreak -ge $tiltThreshold } |
    Group-Object -Property Name |
    ForEach-Object {
        $worst = $_.Group | Sort-Object TiltStreak -Descending | Select-Object -First 1
        Get-TiltMessage -Name $worst.Name -Streak $worst.TiltStreak
    }
)
if ($tiltLines.Count -gt 0) {
    $embedFields.Add(@{ name = "$eSiren Tilt Watch"; value = ($tiltLines -join "`n"); inline = $false })
}

# Promo/demotion alerts
$leagueLines = @(foreach ($player in $playedOnly) {
    $prevLeague = Get-League ([int]$player.PrevMMR)
    $currLeague = Get-League ([int]$player.MMR)
    if ($currLeague.Name -eq $prevLeague.Name) { continue }

    $isPromo       = [int]$player.MMR -gt [int]$player.PrevMMR
    $leagueCrossed = $currLeague.ShortName -ne $prevLeague.ShortName

    if ($leagueCrossed) {
        if ($isPromo) {
            Get-PromotionMessage -Name $player.Name -League $currLeague.Name -Emoji $currLeague.Emoji
        } else {
            Get-DemotionMessage -Name $player.Name -League $currLeague.Name -Emoji $currLeague.Emoji
        }
    } else {
        $arrow = if ($isPromo) { $eArrowUp } else { $eArrowDown }
        $verb  = if ($isPromo) { 'moved up to' } else { 'slipped down to' }
        "$arrow ``$($player.Name)`` $verb **$($currLeague.Name)** $($currLeague.Emoji)"
    }
})
if ($leagueLines.Count -gt 0) {
    $embedFields.Add(@{ name = "$eConfetti League Changes"; value = ($leagueLines -join "`n"); inline = $false })
}

# Weekly leaderboard field on configured day
if ($dayOfWeek -eq $weeklyDay) {
    $weeklyData = @(Invoke-Sqlcmd @sqlParams -Query @"
WITH CurrentSnap AS (
    SELECT LLID, Name, Race, MMR
    FROM   LadderHistory
    WHERE  RunDate = CAST(GETDATE() AS DATE)
),
WeekStart AS (
    SELECT h.LLID, h.MMR
    FROM   LadderHistory h
    INNER JOIN (
        SELECT   LLID, MIN(RunDate) AS OldestDate
        FROM     LadderHistory
        WHERE    RunDate >= CAST(DATEADD(DAY, -7, GETDATE()) AS DATE)
        GROUP BY LLID
    ) oldest ON h.LLID = oldest.LLID AND h.RunDate = oldest.OldestDate
)
SELECT cs.Name, cs.Race, cs.MMR AS CurrentMMR, ws.MMR AS WeekStartMMR, cs.MMR - ws.MMR AS WeeklyChange
FROM CurrentSnap cs JOIN WeekStart ws ON cs.LLID = ws.LLID
ORDER BY WeeklyChange DESC;
"@)

    if ($weeklyData.Count -gt 0) {
        $rank        = 1
        $weeklyLines = $weeklyData | ForEach-Object {
            $medal     = switch ($rank) { 1 { $eGoldMedal } 2 { $eSilverMed } 3 { $eBronzeMed } default { "#$rank" } }
            $changeStr = if ([int]$_.WeeklyChange -gt 0) { "+$($_.WeeklyChange)" } else { "$($_.WeeklyChange)" }
            $league    = Get-League ([int]$_.CurrentMMR)
            $rank++
            "$medal **$($_.Name)** ($($_.Race)) $($league.Emoji) - $changeStr MMR this week"
        }
        $netWeekly    = ($weeklyData | Measure-Object -Property WeeklyChange -Sum).Sum
        $netStr       = if ([int]$netWeekly -ge 0) { "+$netWeekly MMR $eChartUp" } else { "$netWeekly MMR $eChartDown" }
        $weeklyWinner = $weeklyData[0]
        $weeklyLoser  = $weeklyData | Select-Object -Last 1
        $weeklyText   = ($weeklyLines -join "`n") + "`n`nMVP: ``$($weeklyWinner.Name)`` | Loser: ``$($weeklyLoser.Name)`` | Net: $netStr"
        $embedFields.Add(@{ name = "$eBarChart Weekly Standings"; value = $weeklyText; inline = $false })
    }
}

# Only send flavor embed if there's something worth saying
if ($embedFields.Count -gt 0) {
    Send-DiscordEmbed -WebhookUrl $webhookUrl `
        -Title "$eBarChart Session Highlights - $date" `
        -Description '' `
        -Color $flavorColor `
        -Fields @($embedFields.ToArray())
}
#endregion

#region -- Static Webpage -------------------------------------------------------
# Generates /data/web/index.html after every successful run.
# Served by the nginx container - no changes to Discord output.
try {
    $webDir = "$dataRoot/web"
    if (-not (Test-Path $webDir)) { New-Item -ItemType Directory -Path $webDir | Out-Null }

    # Build leaderboard rows
    $allPlayers = @(Invoke-Sqlcmd @sqlParams -Query @"
SELECT
    ap.Name,
    ap.Race,
    ap.MMR,
    ap.Games,
    ap.MaxWS,
    ap.MaxLS,
    ap.WinPercent,
    ap.RatingMax,
    COALESCE(ls.MMR - ap.MMR, 0) AS Change
FROM AllParticipants ap
LEFT JOIN LadderStaging ls ON ap.LLID = ls.LLID
ORDER BY ap.MMR DESC;
"@)

    # Build weekly data if available
    $weeklyRows = @(Invoke-Sqlcmd @sqlParams -Query @"
WITH CurrentSnap AS (
    SELECT LLID, Name, Race, MMR
    FROM   LadderHistory
    WHERE  RunDate = CAST(GETDATE() AS DATE)
),
WeekStart AS (
    SELECT h.LLID, h.MMR
    FROM   LadderHistory h
    INNER JOIN (
        SELECT   LLID, MIN(RunDate) AS OldestDate
        FROM     LadderHistory
        WHERE    RunDate >= CAST(DATEADD(DAY, -7, GETDATE()) AS DATE)
        GROUP BY LLID
    ) oldest ON h.LLID = oldest.LLID AND h.RunDate = oldest.OldestDate
)
SELECT cs.Name, cs.Race, cs.MMR AS CurrentMMR, cs.MMR - ws.MMR AS WeeklyChange
FROM CurrentSnap cs JOIN WeekStart ws ON cs.LLID = ws.LLID
ORDER BY WeeklyChange DESC;
"@)

    function Get-LeagueColor ([int]$DecimalColor) {
        return '#{0:X6}' -f $DecimalColor
    }

    # Returns black or white text depending on badge background luminance.
    # Uses the W3C relative luminance formula so text is always readable.
    function Get-BadgeTextColor ([int]$DecimalColor) {
        $r = (($DecimalColor -shr 16) -band 0xFF) / 255.0
        $g = (($DecimalColor -shr 8)  -band 0xFF) / 255.0
        $b = ( $DecimalColor           -band 0xFF) / 255.0
        # Linearize sRGB channels
        $rL = if ($r -le 0.03928) { $r / 12.92 } else { [Math]::Pow(($r + 0.055) / 1.055, 2.4) }
        $gL = if ($g -le 0.03928) { $g / 12.92 } else { [Math]::Pow(($g + 0.055) / 1.055, 2.4) }
        $bL = if ($b -le 0.03928) { $b / 12.92 } else { [Math]::Pow(($b + 0.055) / 1.055, 2.4) }
        $luminance = 0.2126 * $rL + 0.7152 * $gL + 0.0722 * $bL
        if ($luminance -gt 0.179) { return '#111111' } else { return '#ffffff' }
    }

    function Get-Badge ([int]$DecimalColor, [string]$Emoji, [string]$Name) {
        $bg   = Get-LeagueColor $DecimalColor
        $text = Get-BadgeTextColor $DecimalColor
        return "<span class='badge' style='background:$bg;color:$text'>$Emoji $Name</span>"
    }

    function Get-ChangeCell ([int]$Change) {
        if ($Change -gt 0) { return "<td class='pos'>+$Change</td>" }
        elseif ($Change -lt 0) { return "<td class='neg'>$Change</td>" }
        else { return "<td class='neu'>-</td>" }
    }

    # Leaderboard table rows
    $tableRows = ($allPlayers | ForEach-Object {
        $league     = Get-League ([int]$_.MMR)
        $badge      = Get-Badge $league.Color $league.Emoji $league.Name
        $changeCell = Get-ChangeCell ([int]$_.Change)
        $raceClass  = $_.Race.ToLower()
        "<tr>
            <td><span class='race $raceClass'>$($_.Race)</span> $($_.Name)</td>
            <td>$badge</td>
            <td class='num'>$($_.MMR)</td>
            $changeCell
            <td class='num'>$($_.WinPercent)</td>
            <td class='num'>$($_.MaxWS)</td>
            <td class='num'>$($_.MaxLS)</td>
            <td class='num' title='$($_.Race) all-time peak'>$($_.RatingMax) <span class='muted'>($($_.Race))</span></td>
            <td class='num'>$($_.Games)</td>
        </tr>"
    }) -join "`n"

    # Weekly table rows
    $weeklyTableRows = ''
    if ($weeklyRows.Count -gt 0) {
        $rank = 1
        $weeklyTableRows = ($weeklyRows | ForEach-Object {
            $medal = switch ($rank) { 1 { '🥇' } 2 { '🥈' } 3 { '🥉' } default { $rank } }
            $changeCell = Get-ChangeCell ([int]$_.WeeklyChange)
            $league = Get-League ([int]$_.CurrentMMR)
            $badge  = Get-Badge $league.Color $league.Emoji $league.Name
            $rank++
            "<tr>
                <td>$medal $($_.Name)</td>
                <td><span class='race $($_.Race.ToLower())'>$($_.Race)</span></td>
                <td>$badge</td>
                <td class='num'>$($_.CurrentMMR)</td>
                $changeCell
            </tr>"
        }) -join "`n"
    }

    if ($weeklyRows.Count -gt 0) {
        $weeklySection = @"
        <h2>Weekly Standings</h2>
        <table>
            <thead>
                <tr>
                    <th>Player</th>
                    <th>Race</th>
                    <th>League</th>
                    <th>MMR</th>
                    <th>7-Day Change</th>
                </tr>
            </thead>
            <tbody>
                $weeklyTableRows
            </tbody>
        </table>
"@
    } else {
        $weeklySection = ''
    }

    # Alert sections
    $athSection = ''
    $athPlayers = $apiResponses | Where-Object { $_.NewATH }
    if ($athPlayers) {
        $athItems = ($athPlayers | ForEach-Object {
            "<li>$($_.Name) hit a new <strong>$($_.Race)</strong> all-time high of <strong>$($_.MMR) MMR</strong>!</li>"
        }) -join "`n"
        $athSection = "<div class='alert ath'><h3>New All-Time Highs</h3><ul>$athItems</ul></div>"
    }

    $tiltSection = ''
    $tiltPlayers = $apiResponses | Where-Object { $_.TiltStreak -ge $tiltThreshold }
    if ($tiltPlayers) {
        $tiltItems = ($tiltPlayers | ForEach-Object {
            "<li>$($_.Name) ($($_.Race)) is on a <strong>$($_.TiltStreak)-game</strong> losing streak.</li>"
        }) -join "`n"
        $tiltSection = "<div class='alert tilt'><h3>Tilt Watch</h3><ul>$tiltItems</ul></div>"
    }

    $leagueSection = ''
    $leagueChanges = @(foreach ($player in $playedOnly) {
        $prevLeague = Get-League ([int]$player.PrevMMR)
        $currLeague = Get-League ([int]$player.MMR)
        if ($currLeague.Name -eq $prevLeague.Name) { continue }
        $isPromo  = [int]$player.MMR -gt [int]$player.PrevMMR
        $arrow    = if ($isPromo) { '&#8679;' } else { '&#8681;' }
        $cls      = if ($isPromo) { 'promo' } else { 'demo' }
        $verb     = if ($isPromo) { 'promoted to' } else { 'demoted to' }
        "<li class='$cls'>$arrow $($player.Name) ($($player.Race)) $verb <strong>$($currLeague.Name)</strong></li>"
    })
    if ($leagueChanges.Count -gt 0) {
        $leagueSection = "<div class='alert league'><h3>League Changes</h3><ul>$($leagueChanges -join "`n")</ul></div>"
    }

    $generatedTime = Get-Date -Format 'dddd, MMMM d yyyy h:mm tt UTC'

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="300">
    <title>FxB Ladder Tracker - $date</title>
    <style>
        :root {
            --bg:       #0d1117;
            --surface:  #161b22;
            --border:   #30363d;
            --text:     #e6edf3;
            --muted:    #8b949e;
            --pos:      #3fb950;
            --neg:      #f85149;
            --neu:      #8b949e;
            --accent:   #58a6ff;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: var(--bg);
            color: var(--text);
            padding: 24px;
            max-width: 1100px;
            margin: 0 auto;
        }
        header {
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid var(--border);
        }
        header h1 { font-size: 1.6rem; color: var(--accent); }
        header .meta { font-size: 0.8rem; color: var(--muted); text-align: right; }
        h2 {
            font-size: 1.1rem;
            color: var(--muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin: 28px 0 12px;
        }
        h3 { font-size: 1rem; margin-bottom: 8px; }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9rem;
            background: var(--surface);
            border-radius: 8px;
            overflow: hidden;
        }
        thead tr { background: #21262d; }
        th {
            padding: 10px 14px;
            text-align: left;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--muted);
            white-space: nowrap;
        }
        td {
            padding: 10px 14px;
            border-top: 1px solid var(--border);
            vertical-align: middle;
        }
        tr:hover td { background: #1c2128; }
        .num { text-align: right; font-variant-numeric: tabular-nums; }
        .pos { color: var(--pos); text-align: right; font-weight: 600; }
        .neg { color: var(--neg); text-align: right; font-weight: 600; }
        .neu { color: var(--neu); text-align: right; }
        .badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
            color: #fff;
            white-space: nowrap;
        }
        .muted { color: var(--muted); font-size: 0.8em; }
        .race {
            display: inline-block;
            padding: 1px 6px;
            border-radius: 4px;
            font-size: 0.7rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-right: 4px;
        }
        .race.zerg    { background: #6e40c9; }
        .race.terran  { background: #1d6fa4; }
        .race.protoss { background: #b8860b; color: #000; }
        .race.random  { background: #444; }
        .alert {
            border-radius: 8px;
            padding: 14px 18px;
            margin-top: 16px;
            font-size: 0.9rem;
        }
        .alert ul { padding-left: 20px; margin-top: 6px; }
        .alert li { padding: 3px 0; }
        .ath   { background: #1a2f1a; border-left: 3px solid var(--pos); }
        .tilt  { background: #2f1a1a; border-left: 3px solid var(--neg); }
        .league { background: #1a1f2f; border-left: 3px solid var(--accent); }
        .promo { color: var(--pos); }
        .demo  { color: var(--neg); }
        .alerts-row { display: flex; gap: 16px; flex-wrap: wrap; }
        .alerts-row .alert { flex: 1; min-width: 260px; }
        footer {
            margin-top: 32px;
            padding-top: 16px;
            border-top: 1px solid var(--border);
            font-size: 0.75rem;
            color: var(--muted);
            text-align: center;
        }
    </style>
</head>
<body>
    <header>
        <div>
            <h1>FxB Ladder Tracker</h1>
            <div style="color:var(--muted);font-size:0.85rem;margin-top:4px">Formless Bearsloths</div>
        </div>
        <div class="meta">
            <div>$date</div>
            <div>Generated $generatedTime</div>
            <div style="margin-top:4px">Auto-refreshes every 5 minutes</div>
        </div>
    </header>

    <div class="alerts-row">
        $athSection
        $tiltSection
        $leagueSection
    </div>

    <h2>Daily Leaderboard</h2>
    <table>
        <thead>
            <tr>
                <th>Player</th>
                <th>League</th>
                <th class="num">MMR</th>
                <th class="num">Today</th>
                <th class="num">Win %</th>
                <th class="num">Best W Streak</th>
                <th class="num">Best L Streak</th>
                <th class="num">Peak MMR (Race)</th>
                <th class="num">Total Games</th>
            </tr>
        </thead>
        <tbody>
            $tableRows
        </tbody>
    </table>

    $weeklySection

    <footer>
        Formless Bearsloths Ladder Tracker &bull; Data from SC2Pulse &bull; $generatedTime
    </footer>
</body>
</html>
"@

    $html | Out-File -FilePath "$webDir/index.html" -Encoding utf8 -Force
    Write-Verbose "Static webpage written to $webDir/index.html" -Verbose

} catch {
    Write-Warning "Failed to generate static webpage: $_"
    # Non-fatal - Discord already posted successfully, don't fail the run over this
}
#endregion

# Success - update RunControl
Invoke-Sqlcmd @sqlParams -Query @"
UPDATE RunControl SET LastRunStatus = 'Success', LastRunPlayers = $processedCount WHERE ID = 1;
"@

$playedOnly | Format-Table
Stop-Transcript
exit 0

} catch {
    $errMsg = $_.ToString()
    Write-Error "Fatal error: $errMsg"

    # Update RunControl with failure
    try {
        $safeErr = $errMsg.Replace("'", "''")
        if ($safeErr.Length -gt 1900) { $safeErr = $safeErr.Substring(0, 1900) }
        Invoke-Sqlcmd @sqlParams -Query @"
UPDATE RunControl
SET LastRunStatus = 'Failed', LastRunPlayers = $processedCount, LastRunError = '$safeErr'
WHERE ID = 1;
"@
    } catch { Write-Warning "Could not update RunControl: $_" }

    # Post failure notification to Discord
    Send-FailureEmbed -ErrorMessage $errMsg -PlayersProcessed $processedCount

    Stop-Transcript
    exit 1
}