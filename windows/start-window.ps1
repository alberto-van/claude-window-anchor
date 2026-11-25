# Windows version of start-window.sh: sends Claude a one-word prompt so the
# usage window starts early. Run by Task Scheduler (see install-task.ps1).
# Works on Windows PowerShell 5.1 and PowerShell 7.
#
# Exit codes: 0 anchored, 1 gave up after all attempts, 2 login expired.

$ErrorActionPreference = 'Continue'

$RepoDir          = Split-Path -Parent $PSScriptRoot
$TokenFile        = Join-Path $RepoDir 'oauth-token'
$LogDir           = Join-Path $env:LOCALAPPDATA 'claude-window'
$LogFile          = Join-Path $LogDir 'claude-window.log'
$AttemptTimeout   = 180              # blind kill; above API_TIMEOUT_MS*retries so the CLI errors first
$NetworkWaitMax   = 600              # wait up to this long for api.anthropic.com
$RetryDelays      = @(60, 180, 300, 600, 900, 900)  # pauses before attempts 2..7 (~63 min)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Output $line
}

function Send-Notification([string]$Message) {
    # Toast through Windows PowerShell's app id; silently skipped if unavailable.
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $escaped = [Security.SecurityElement]::Escape($Message)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>Claude window anchor</text><text>$escaped</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { }
}

# Guard against a missed weekday run firing on a weekend.
$today = (Get-Date).DayOfWeek
if ($today -eq 'Saturday' -or $today -eq 'Sunday') {
    Write-Log "weekend ($today) - skipping"
    exit 0
}

# Long-lived token from `claude setup-token`, kept out of the repo. Strip all
# whitespace, not just the ends: a token copied from a terminal often has a
# line break where the terminal wrapped it.
if (Test-Path $TokenFile) {
    $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content -Raw $TokenFile) -replace '\s', ''
}

# Fail fast rather than stall. Claude Code's own defaults are generous:
# API_TIMEOUT_MS is 600000 (10 min) and CLAUDE_CODE_MAX_RETRIES is 10, so a
# stalled request outlives $AttemptTimeout and gets killed with no error to
# log. Keep both inside $AttemptTimeout so the CLI reports a real failure
# first, and let this script's own backoff do the retrying.
$env:API_TIMEOUT_MS                          = '45000'
$env:CLAUDE_CODE_MAX_RETRIES                 = '2'
$env:CLAUDE_CODE_NONSTREAMING_TIMEOUT_RETRIES = '0'
$env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS    = '5000'   # don't idle 10 min after READY

# Drop startup network calls this ping does not need: updates, telemetry,
# error reporting, feature flags, claude.ai connectors, session-title request.
# (Not --bare: that mode ignores CLAUDE_CODE_OAUTH_TOKEN, which we rely on.)
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:DISABLE_AUTOUPDATER                      = '1'
$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE       = '1'
$env:ENABLE_CLAUDEAI_MCP_SERVERS              = 'false'
$env:CLAUDE_CODE_DISABLE_CLAUDE_MDS           = '1'
$env:CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS     = '1'
$env:CLAUDE_CODE_DISABLE_AUTO_MEMORY          = '1'
$env:CLAUDE_CODE_DISABLE_BACKGROUND_TASKS     = '1'
$env:CLAUDE_CODE_DISABLE_CRON                 = '1'

# Find claude: native installer first, then whatever is on PATH (npm's claude.cmd).
$Claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $Claude)) {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $Claude = $cmd.Source } else {
        Write-Log 'claude not found - install Claude Code or add it to PATH'
        Send-Notification 'claude not found. Install Claude Code or add it to PATH.'
        exit 1
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Any HTTP response (even 404) means the API host is reachable.
function Test-Api {
    try {
        Invoke-WebRequest -Uri 'https://api.anthropic.com' -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
        return $true
    } catch {
        return [bool]$_.Exception.Response
    }
}

function Wait-ForNetwork {
    $waited = 0
    while (-not (Test-Api)) {
        if ($waited -ge $NetworkWaitMax) {
            Write-Log "network still unreachable after ${NetworkWaitMax}s - trying anyway"
            return
        }
        Start-Sleep -Seconds 10
        $waited += 10
    }
    if ($waited -gt 0) { Write-Log "network reachable after ${waited}s" }
}

# Empty MCP config as a file: avoids quoting JSON on the Windows command line.
$McpFile = Join-Path $env:TEMP 'claude-window-mcp.json'
Set-Content -Path $McpFile -Value '{"mcpServers":{}}' -Encoding ASCII

function ConvertTo-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

# Minimal ping: no MCP servers, plugins, settings, skills, tools or saved session.
$ClaudeArgs = @(
    '-p', 'Reply with only the word READY. Do not use any tools.',
    '--model', 'haiku', '--max-turns', '1',
    '--strict-mcp-config', '--mcp-config', $McpFile,
    '--setting-sources', '', '--disable-slash-commands', '--tools', '',
    '--permission-prompts', 'none',
    '--no-chrome', '--no-session-persistence'
)

# Returns @{ Code = exit code (124 on timeout); Output = combined text }.
function Invoke-Claude {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Claude
    $psi.Arguments = ($ClaudeArgs | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($AttemptTimeout * 1000)) {
        # Kill the whole tree: claude.cmd starts node as a child.
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        return @{ Code = 124; Output = "timed out after ${AttemptTimeout}s" }
    }
    $p.WaitForExit()
    $text = ($out.Result + $err.Result) -replace "[\r\n]+", ''
    return @{ Code = $p.ExitCode; Output = $text }
}

$MaxAttempts = $RetryDelays.Count + 1
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Wait-ForNetwork
    Write-Log ("attempt $attempt/$MaxAttempts (model haiku) at {0}" -f (Get-Date -Format 'HH:mm'))
    $r = Invoke-Claude
    if ($r.Code -eq 0) {
        Write-Log "anchored -> $($r.Output)"
        exit 0
    }

    Write-Log "failed -> $($r.Output)"

    # An expired token will not fix itself - stop and tell the user.
    if ($r.Output -match 'authenticate|401|oauth') {
        Write-Log "AUTH EXPIRED - run 'claude setup-token' and save the new token to $TokenFile"
        Send-Notification 'Auth expired. Run claude setup-token and save it to oauth-token.'
        exit 2
    }

    if ($attempt -lt $MaxAttempts) {
        $delay = $RetryDelays[$attempt - 1]
        Write-Log "retrying in ${delay}s"
        Start-Sleep -Seconds $delay
    }
}

Write-Log "gave up after $MaxAttempts attempts"
Send-Notification "Failed to anchor the usage window after $MaxAttempts attempts."
exit 1
