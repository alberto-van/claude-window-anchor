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
$AttemptTimeout   = 120              # kill a hung claude call after this many seconds
$NetworkWaitMax   = 600              # wait up to this long for api.anthropic.com
$RetryDelays      = @(60, 180, 300)  # pause before attempts 2, 3 and 4

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
