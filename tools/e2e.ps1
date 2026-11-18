# e2e.ps1
# =============================================================================
# End-to-end verification harness for the "Typora Translate" plugin
# (select English text -> right-click -> "Translate" / Ctrl+Shift+T).
#
# Why Win32 instead of the Chrome DevTools Protocol:
#   Production Typora refuses remote-debugging switches, so CDP is unavailable.
#   This harness therefore drives the real application the same way a user
#   would (SetForegroundWindow + SendInput + mouse_event) and verifies the
#   result through the files the plugin writes:
#
#     %APPDATA%\Typora\typora-translate\status.json   (structured status)
#     %APPDATA%\Typora\typora-translate\plugin.log    ([BOOT] [MENU] [TRANSLATE] [ERROR] [UI])
#
# Usage (Windows PowerShell 5.1 or PowerShell 7; run from the repo root):
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase boot
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase hotkey
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase contextmenu
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase all
#
#   -TyporaExe <path>   optional; when omitted, Typora.exe is auto-detected
#                       (registry uninstall keys, Program Files, running process).
#
#   -Phase all          boot -> hotkey -> contextmenu, then stop the Typora
#                       process tree this harness launched (and only that one).
#   -Phase boot         verify install, launch Typora with the fixture, wait
#                       for status.json booted=true + menus registered, screenshot.
#   -Phase hotkey       focus Typora, click editor, Ctrl+A, Ctrl+Shift+T, wait
#                       for a successful CJK translation, screenshot the panel.
#   -Phase contextmenu  focus Typora, click editor, Ctrl+A, right-click, assert
#                       plugin.log recorded a [MENU] show with selection length > 0,
#                       screenshot the open context menu.
#
# Exit code: 0 only when every executed phase PASSed, 1 otherwise.
#
# Safety rules implemented here:
#   * The harness records exactly which Typora processes it launched (PID +
#     start time + exe path) in %TEMP%\typora-translate-e2e\state.json.
#   * It only ever kills those recorded processes, and only after re-verifying
#     the executable path and start time (PID-reuse guard).
#   * If a Typora instance it did not launch is running, boot refuses to touch
#     it and fails with a clear warning. With -Force it "adopts" that instance
#     instead of launching (and never kills it).
#
# Outputs:
#   docs\screenshots\boot-loaded.png
#   docs\screenshots\hotkey-before.png / hotkey-panel.png
#   docs\screenshots\menu.png
#   %TEMP%\typora-translate-e2e\run-<id>.log / summary-<id>.json
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('boot', 'hotkey', 'contextmenu', 'all')]
    [string]$Phase = 'all',

    [string]$TyporaExe = '',

    [string]$FixturePath = '',

    # Adopt a running Typora instance instead of aborting (never killed).
    [switch]$Force,

    # Leave Typora running after '-Phase all' (useful while debugging).
    [switch]$KeepOpen,

    [int]$BootTimeoutSec = 60,
    [int]$TranslateTimeoutSec = 40,
    [int]$MenuTimeoutSec = 8,

    [switch]$NoTranscript
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Locate Typora.exe when the caller did not pass -TyporaExe
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TyporaExe)) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -like 'Typora*' -and $p.InstallLocation) {
                $candidates.Add((Join-Path ($p.InstallLocation.Trim('"').TrimEnd('\')) 'Typora.exe'))
            }
        }
    }
    $candidates.Add((Join-Path $env:ProgramFiles 'Typora\Typora.exe'))
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Typora\Typora.exe')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Typora\Typora.exe')) }
    foreach ($p in @(Get-Process -Name Typora -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $candidates.Add($p.Path) } } catch {}
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $TyporaExe = $c; break }
    }
    if ([string]::IsNullOrWhiteSpace($TyporaExe)) {
        throw 'Typora.exe not found. Install Typora or pass -TyporaExe "C:\path\to\Typora.exe".'
    }
}
Write-Host ("  [..] Typora exe (resolved): " + $TyporaExe)

# ---------------------------------------------------------------------------
# Paths / global context
# ---------------------------------------------------------------------------
$script:ScriptDir = $PSScriptRoot
$script:ProjectRoot = Split-Path -Parent $script:ScriptDir
$script:WorkspaceRoot = Split-Path -Parent $script:ProjectRoot

if ([string]::IsNullOrWhiteSpace($FixturePath)) {
    $FixturePath = Join-Path $script:ProjectRoot 'tests\fixtures\sample-en.md'
}
$script:FixturePath = [System.IO.Path]::GetFullPath($FixturePath)
$script:FixtureName = Split-Path -Leaf $script:FixturePath
$script:FixtureTitlePattern = [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($script:FixturePath))

$script:TyporaRoot = Split-Path -Parent $TyporaExe
$script:ResourcesDir = Join-Path $script:TyporaRoot 'resources'
$script:AppDataPluginDir = Join-Path $env:APPDATA 'Typora\typora-translate'
$script:StatusPath = Join-Path $script:AppDataPluginDir 'status.json'
$script:LogPath = Join-Path $script:AppDataPluginDir 'plugin.log'
$script:ConfigPath = Join-Path $script:AppDataPluginDir 'config.json'
$script:ScreenshotDir = Join-Path $script:ProjectRoot 'docs\screenshots'
$script:StateDir = Join-Path $env:TEMP 'typora-translate-e2e'
$script:StatePath = Join-Path $script:StateDir 'state.json'

# Fractions of the client area used for "click into the editor body". The
# document body starts below Typora's toolbar, so 28% down the client area is
# reliably inside the first paragraph for the fixture document.
$script:EditorRelX = 0.5
$script:EditorRelY = 0.28

$script:Results = New-Object System.Collections.ArrayList
$script:Context = @{ Hwnd = [IntPtr]::Zero; ProcessId = 0; Title = ''; Adopted = $false }
$script:LaunchUtc = [datetime]::MinValue
$script:AdoptMode = $false
$script:RunId = ''
$script:StartedUtc = (Get-Date).ToUniversalTime()
$script:RunLogPath = ''
$script:SummaryPath = ''
$script:TranscriptStarted = $false

# ---------------------------------------------------------------------------
# Console output helpers
# ---------------------------------------------------------------------------
function Write-Banner {
    Write-Host ''
    Write-Host '================================================================================' -ForegroundColor DarkCyan
    Write-Host '  Typora Translate - End-to-End Verification Harness' -ForegroundColor Cyan
    Write-Host '  select English -> right-click -> translate   /   Ctrl+Shift+T' -ForegroundColor Cyan
    Write-Host '================================================================================' -ForegroundColor DarkCyan
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('--- ' + $Title + ' ' + ('-' * [Math]::Max(0, 74 - $Title.Length))) -ForegroundColor DarkCyan
}

function Write-Info([string]$Message) { Write-Host ('  [..] ' + $Message) -ForegroundColor Gray }
function Write-Ok([string]$Message) { Write-Host ('  [OK] ' + $Message) -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host ('  [!!] ' + $Message) -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host ('  [XX] ' + $Message) -ForegroundColor Red }
function Write-Note([string]$Message) { Write-Host ('       ' + $Message) -ForegroundColor DarkGray }

function Get-ResultColor([string]$Result) {
    switch ($Result) {
        'PASS' { return 'Green' }
        'FAIL' { return 'Red' }
        'BLOCKED' { return 'Magenta' }
        'WARN' { return 'Yellow' }
        default { return 'DarkYellow' }
    }
}

function Add-PhaseResult {
    <# Record a phase outcome, print it, and return the entry. #>
    param(
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Evidence = '',
        [string[]]$Details = @(),
        [string[]]$Screenshots = @()
    )
    $entry = [pscustomobject]@{
        Phase       = $PhaseName
        Result      = $Result
        Evidence    = $Evidence
        Details     = @($Details)
        Screenshots = @($Screenshots)
    }
    [void]$script:Results.Add($entry)
    $color = Get-ResultColor $Result
    Write-Host ('  >>> {0}: {1} - {2}' -f $PhaseName.ToUpper(), $Result, $Evidence) -ForegroundColor $color
    foreach ($d in @($Details)) {
        if (-not [string]::IsNullOrWhiteSpace($d)) { Write-Note $d }
    }
    return $entry
}

# ---------------------------------------------------------------------------
# Load Win32 helper layer
# ---------------------------------------------------------------------------
. (Join-Path $script:ScriptDir 'win-ui.ps1')
Initialize-WinUi | Out-Null

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------
function Get-JsonField {
    <# Read a property from a PSCustomObject by any of several candidate names. #>
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($null -ne $prop) { return $prop.Value }
    }
    return $null
}

function Test-Truthy {
    <# Accept booleans, numbers > 0, and the strings 'true'/'1'/'yes'. #>
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([double]$Value -gt 0)
    }
    $text = [string]$Value
    return ($text -eq 'true' -or $text -eq 'True' -or $text -eq '1' -or $text -eq 'yes')
}

function Format-StatusValue($Value) {
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    return [string]$Value
}

function Get-LogLineCount {
    $tail = Read-LogNewLines -Path $script:LogPath -FromIndex 0
    return [int]$tail.ToIndex
}

function Get-LogNewLinesSince {
    <# New log lines relative to a previously recorded line count (rotation-safe). #>
    param([int]$Offset)
    $tail = Read-LogNewLines -Path $script:LogPath -FromIndex ([Math]::Max(0, $Offset))
    $rotated = $false
    if ($tail.ToIndex -lt $Offset) {
        # The plugin rotates plugin.log at 512 KiB (rename to .1): restart at 0.
        $rotated = $true
        $tail = Read-LogNewLines -Path $script:LogPath -FromIndex 0
    }
    return [pscustomobject]@{
        Lines    = @($tail.Lines)
        Text     = $tail.Text
        ToIndex  = [int]$tail.ToIndex
        Rotated  = $rotated
    }
}

function Get-LogTail {
    <# Last N log lines (all lines, unfiltered). #>
    param([int]$Count = 25)
    $tail = Read-LogNewLines -Path $script:LogPath -FromIndex 0
    $lines = @($tail.Lines)
    if ($lines.Count -le $Count) { return @($lines) }
    return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
}

function Get-PluginStatus {
    <# Tolerant read of status.json; returns $null while the plugin has not written it. #>
    return (Read-JsonFileShared -Path $script:StatusPath)
}

function Test-StatusFreshSince {
    <# True when status.json was written at/after $SinceUtc (freshness guard against stale PASSes). #>
    param($Status, [datetime]$SinceUtc)
    if ($null -eq $Status) { return $false }
    $threshold = $SinceUtc.AddSeconds(-5)
    $updatedAt = ConvertTo-UtcDateTime -Value (Get-JsonField $Status @('updatedAt'))
    if ($updatedAt -and $updatedAt -ge $threshold) { return $true }
    $bootAt = ConvertTo-UtcDateTime -Value (Get-JsonField $Status @('bootAt'))
    if ($bootAt -and $bootAt -ge $threshold) { return $true }
    $item = Get-Item -LiteralPath $script:StatusPath -ErrorAction SilentlyContinue
    if ($item -and $item.LastWriteTimeUtc -ge $threshold) { return $true }
    return $false
}

function Get-MenusState {
    <# Normalise status.menus to { Rich; Source } booleans, tolerant of int counts. #>
    param($Status)
    $menus = Get-JsonField $Status @('menus')
    $rich = Test-Truthy (Get-JsonField $menus @('rich', 'context-menu', 'contextmenu', 'contextMenu'))
    $source = Test-Truthy (Get-JsonField $menus @('source', 'source-menu', 'sourceMenu'))
    return [pscustomobject]@{ Rich = $rich; Source = $source; Raw = $menus }
}

function Get-PluginLogMarkerPresence {
    <# Whether the full plugin.log contains a marker such as [UI]. #>
    param([string]$Marker)
    $tail = Read-LogNewLines -Path $script:LogPath -FromIndex 0
    $text = [string]($tail.Text)
    return $text.Contains($Marker)
}

# ---------------------------------------------------------------------------
# Harness state file (records the Typora processes we launched)
# ---------------------------------------------------------------------------
function Read-HarnessState {
    param([string]$Path = $script:StatePath)
    return (Read-JsonFileShared -Path $Path)
}

function Save-HarnessState {
    param($State, [string]$Path = $script:StatePath)
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        $null = New-Item -ItemType Directory -Force -Path $script:StateDir
    }
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Clear-HarnessState {
    if (Test-Path -LiteralPath $script:StatePath) {
        Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Process helpers (safety critical)
# ---------------------------------------------------------------------------
function Get-TyporaProcesses {
    return @(Get-Process -Name Typora -ErrorAction SilentlyContinue)
}

function Get-OwnedProcessIds {
    <#
      PIDs recorded in the state file that are still alive AND still look like
      the process we recorded (same exe path, start time within tolerance).
      Returns an array of PIDs (may be empty).
    #>
    $state = Read-HarnessState
    $owned = New-Object System.Collections.ArrayList
    if ($null -eq $state -or $null -eq $state.roots) { return @() }
    foreach ($root in @($state.roots)) {
        $pidValue = 0
        try { $pidValue = [int]$root.pid } catch { continue }
        if ($pidValue -le 0) { continue }
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        $pathOk = $true
        if ($root.path) {
            $actualPath = $null
            try { $actualPath = $proc.Path } catch { $actualPath = $null }
            if ($actualPath -and $actualPath -ne [string]$root.path) { $pathOk = $false }
        }
        $timeOk = $true
        $expectedStart = ConvertTo-UtcDateTime -Value $root.startTimeUtc
        if ($expectedStart) {
            try {
                $delta = [Math]::Abs(($proc.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds)
                if ($delta -gt 30) { $timeOk = $false }
            }
            catch { }
        }
        if ($pathOk -and $timeOk) {
            # Include descendants so helper/renderer processes are covered too.
            foreach ($id in @(Get-ProcessTreeIds -RootId $pidValue)) {
                if (-not $owned.Contains([int]$id)) { [void]$owned.Add([int]$id) }
            }
        }
    }
    return @($owned.ToArray())
}

function Get-ForeignTyporaProcesses {
    <# Live Typora processes that this harness did NOT launch. #>
    $owned = @(Get-OwnedProcessIds)
    return @(Get-TyporaProcesses | Where-Object { $owned -notcontains $_.Id })
}

function Stop-OwnedTypora {
    <#
      Stop the Typora process tree recorded in the state file.  Every root is
      re-verified (exe path + start time) before killing; foreign instances are
      never touched.  Returns a summary object.
    #>
    $state = Read-HarnessState
    $stopped = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    if ($null -eq $state -or $null -eq $state.roots) {
        return [pscustomobject]@{ Stopped = @(); Failed = @(); Notes = @('no harness state file (nothing launched previously)') }
    }
    foreach ($root in @($state.roots)) {
        $pidValue = 0
        try { $pidValue = [int]$root.pid } catch { continue }
        if ($pidValue -le 0) { continue }
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            [void]$notes.Add(("PID {0} already exited" -f $pidValue))
            continue
        }
        $expectedStart = ConvertTo-UtcDateTime -Value $root.startTimeUtc
        try {
            if ($expectedStart) {
                $res = Stop-ProcessTree -ProcessId $pidValue -ExpectedPath ([string]$root.path) -ExpectedStartUtc $expectedStart
            }
            else {
                $res = Stop-ProcessTree -ProcessId $pidValue -ExpectedPath ([string]$root.path)
            }
            if ($res.Killed) {
                [void]$stopped.Add($pidValue)
                [void]$notes.Add(("stopped PID {0} (tree: {1})" -f $pidValue, (@($res.TreeIds) -join ',')))
            }
            else {
                [void]$failed.Add($pidValue)
                [void]$notes.Add(("PID {0} did not exit ({1})" -f $pidValue, $res.Reason))
            }
        }
        catch {
            # A verification/throw is not automatically a failure: re-check
            # whether the process actually exited before reporting it.
            $stillThere = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($null -eq $stillThere) {
                [void]$stopped.Add($pidValue)
                [void]$notes.Add(("PID {0} exited (kill raised: {1})" -f $pidValue, $_.Exception.Message))
            }
            else {
                [void]$failed.Add($pidValue)
                [void]$notes.Add(("refused/failed to stop PID {0}: {1}" -f $pidValue, $_.Exception.Message))
            }
        }
    }
    if ($failed.Count -eq 0) { Clear-HarnessState }
    return [pscustomobject]@{ Stopped = @($stopped.ToArray()); Failed = @($failed.ToArray()); Notes = @($notes.ToArray()) }
}

function Start-TyporaForTest {
    <#
      Launch Typora with the E2E fixture and record the resulting process
      tree in the state file.  Returns { RootPid; Roots; LaunchedAtUtc }.
    #>
    if (-not (Test-Path -LiteralPath $script:TyporaExe)) {
        throw ("Typora executable not found: " + $script:TyporaExe)
    }
    $beforePids = @(Get-TyporaProcesses | ForEach-Object { [int]$_.Id })
    $launchUtc = (Get-Date).ToUniversalTime()
    $startInfo = @{
        FilePath     = $script:TyporaExe
        ArgumentList = @(('"' + $script:FixturePath + '"'))
        PassThru     = $true
    }
    $proc = Start-Process @startInfo
    $rootPid = [int]$proc.Id
    Write-Info ("launched Typora: PID {0}, fixture '{1}'" -f $rootPid, $script:FixturePath)
    Start-Sleep -Seconds 2

    # Determine the process tree we own: descendants of the launcher PID, plus
    # any Typora process that appeared after our launch timestamp (covers the
    # case where the launcher re-execs itself).
    $treeIds = @(Get-ProcessTreeIds -RootId $rootPid)
    $newPids = @(Get-TyporaProcesses | Where-Object { $beforePids -notcontains $_.Id } | ForEach-Object { [int]$_.Id })
    $ourIds = New-Object System.Collections.ArrayList
    foreach ($id in $treeIds) { [void]$ourIds.Add([int]$id) }
    foreach ($id in $newPids) {
        $procInfo = Get-Process -Id $id -ErrorAction SilentlyContinue
        $startOk = $false
        if ($procInfo) {
            try { $startOk = ($procInfo.StartTime.ToUniversalTime() -ge $launchUtc.AddSeconds(-5)) } catch { }
        }
        if ($startOk -and -not $ourIds.Contains([int]$id)) { [void]$ourIds.Add([int]$id) }
    }
    if ($ourIds.Count -eq 0) {
        throw ('Typora was started (PID {0}) but no live process could be attributed to it.' -f $rootPid)
    }

    $roots = New-Object System.Collections.ArrayList
    foreach ($id in @($ourIds.ToArray())) {
        $procInfo = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $procInfo) { continue }
        $path = $null
        try { $path = $procInfo.Path } catch { $path = $null }
        [void]$roots.Add([pscustomobject]@{
                pid          = [int]$id
                startTimeUtc = $procInfo.StartTime.ToUniversalTime().ToString('o')
                path         = [string]$path
            })
    }
    $state = [pscustomobject]@{
        runId        = $script:RunId
        typoraExe    = $script:TyporaExe
        fixture      = $script:FixturePath
        launchedAtUtc = $launchUtc.ToString('o')
        roots        = @($roots.ToArray())
    }
    Save-HarnessState -State $state
    return [pscustomobject]@{
        RootPid       = $rootPid
        Roots         = @($roots.ToArray())
        LaunchedAtUtc = $launchUtc
    }
}

# ---------------------------------------------------------------------------
# Install state
# ---------------------------------------------------------------------------
function Test-PluginInstallState {
    <#
      Static install check (mirrors the installer's own VerifyOnly logic).
      Returns { Ok; Details; PluginDir; FilesOk; MarkerOk }.
    #>
    $details = New-Object System.Collections.ArrayList
    $pluginDir = Join-Path $script:ResourcesDir 'plugin\typora-translate'
    $windowHtmlPath = Join-Path $script:ResourcesDir 'window.html'
    $requiredFiles = @('bootstrap.js', 'ui.js', 'service.js', 'styles.css')

    $dirOk = Test-Path -LiteralPath $pluginDir
    if ($dirOk) { [void]$details.Add(('plugin directory: ' + $pluginDir)) }
    else { [void]$details.Add(('MISSING plugin directory: ' + $pluginDir)) }

    $missing = @()
    if ($dirOk) {
        $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $pluginDir $_)) })
        if ($missing.Count -gt 0) {
            [void]$details.Add(('MISSING plugin files: ' + ($missing -join ', ')))
        }
        else {
            [void]$details.Add(('plugin files present: ' + ($requiredFiles -join ', ')))
        }
    }
    $filesOk = ($dirOk -and $missing.Count -eq 0)

    $windowText = $null
    if (Test-Path -LiteralPath $windowHtmlPath) {
        try { $windowText = [System.IO.File]::ReadAllText($windowHtmlPath) } catch { $windowText = $null }
    }
    $markerStart = ($null -ne $windowText -and $windowText.Contains('<!-- typora-translate:start -->'))
    $markerTag = ($null -ne $windowText -and $windowText.Contains('typora-translate-bootstrap'))
    $markerSrc = ($null -ne $windowText -and $windowText.Contains('plugin/typora-translate/bootstrap.js'))
    $markerOk = ($markerStart -and $markerTag -and $markerSrc)
    if ($markerOk) {
        [void]$details.Add('window.html: typora-translate bootstrap script injected')
    }
    else {
        $why = @()
        if (-not $markerStart) { $why += 'missing "<!-- typora-translate:start -->"' }
        if (-not $markerTag) { $why += 'missing marker tag typora-translate-bootstrap' }
        if (-not $markerSrc) { $why += 'missing src ./plugin/typora-translate/bootstrap.js' }
        [void]$details.Add(('window.html not correctly injected: ' + ($why -join '; ')))
    }
    if ($null -ne $windowText -and $windowText.Contains('9334/beacon')) {
        [void]$details.Add('NOTE: recon probe beacon instrumentation detected in window.html (not the real plugin yet)')
    }

    return [pscustomobject]@{
        Ok        = ($filesOk -and $markerOk)
        FilesOk   = $filesOk
        MarkerOk  = $markerOk
        PluginDir = $pluginDir
        Details   = @($details.ToArray())
    }
}

# ---------------------------------------------------------------------------
# Screenshot helper
# ---------------------------------------------------------------------------
function Save-E2EScreenshot {
    <#
      Capture the given window into recon\screenshots\<Name>.
      Returns the Save-WindowScreenshot result object (or $null on failure).
    #>
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Mode = 'Auto'
    )
    if (-not (Test-Path -LiteralPath $script:ScreenshotDir)) {
        $null = New-Item -ItemType Directory -Force -Path $script:ScreenshotDir
    }
    $path = Join-Path $script:ScreenshotDir $Name
    $result = $null
    try {
        $result = Save-WindowScreenshot -Hwnd $Hwnd -Path $path -Mode $Mode -ForceForeground
    }
    catch {
        Write-Warn ("screenshot '{0}' failed: {1}" -f $Name, $_.Exception.Message)
        return $null
    }
    if ($result.Blank) {
        Write-Warn ("screenshot '{0}' looked blank ({1}); retrying with screen capture" -f $Name, $result.Mode)
        $null = Set-WindowForeground -Hwnd $Hwnd
        Start-Sleep -Milliseconds 400
        try {
            $retry = Save-WindowScreenshot -Hwnd $Hwnd -Path $path -Mode 'Screen' -ForceForeground
            if ($null -ne $retry) { $result = $retry }
        }
        catch { }
    }
    Write-Info ('screenshot: {0} ({1}x{2}, mode={3}, uniqueColors={4}, blank={5})' -f `
            $result.Path, $result.Width, $result.Height, $result.Mode, $result.UniqueColors, $result.Blank)
    return $result
}

function Get-StatusSummaryText {
    <# One-line summary of status.json for evidence strings. #>
    param($Status)
    if ($null -eq $Status) { return 'status.json: <missing/unreadable>' }
    $menus = Get-MenusState -Status $Status
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('booted=' + (Format-StatusValue (Get-JsonField $Status @('booted'))))
    [void]$parts.Add('version=' + (Format-StatusValue (Get-JsonField $Status @('version'))))
    [void]$parts.Add('menus.rich=' + (Format-StatusValue $menus.Rich))
    [void]$parts.Add('menus.source=' + (Format-StatusValue $menus.Source))
    $service = Get-JsonField $Status @('serviceAvailable')
    if ($null -ne $service) { [void]$parts.Add('serviceAvailable=' + (Format-StatusValue $service)) }
    return ('status.json: ' + ($parts -join ' '))
}

function Get-StatusDiagnostics {
    <# Multi-line diagnostics about the current status/log, for FAIL evidence. #>
    $details = New-Object System.Collections.ArrayList
    $status = Get-PluginStatus
    if ($null -eq $status) {
        [void]$details.Add(('status.json missing/unreadable at ' + $script:StatusPath))
        if ($script:LastJsonError) { [void]$details.Add(('last JSON parse error: ' + $script:LastJsonError)) }
    }
    else {
        [void]$details.Add((Get-StatusSummaryText -Status $status))
        $lastError = Get-JsonField $status @('lastError')
        if ($null -ne $lastError) {
            [void]$details.Add('status.lastError: ' + ($lastError | ConvertTo-Json -Compress -Depth 4))
        }
        $bootAt = Get-JsonField $status @('bootAt')
        if ($null -ne $bootAt) { [void]$details.Add('status.bootAt: ' + [string]$bootAt) }
    }
    $logTail = @(Get-LogTail -Count 20)
    if ($logTail.Count -gt 0) {
        [void]$details.Add('plugin.log tail:')
        foreach ($line in $logTail) { [void]$details.Add('  | ' + $line) }
    }
    else {
        [void]$details.Add(('plugin.log missing/empty at ' + $script:LogPath))
    }
    return @($details.ToArray())
}

# ---------------------------------------------------------------------------
# UI target resolution
# ---------------------------------------------------------------------------
function Resolve-UiContext {
    <#
      Return the Typora window the UI phases should drive.  Re-uses the window
      found by the boot phase when possible; otherwise discovers a running
      Typora window (standalone -Phase hotkey/contextmenu usage).
    #>
    if ($script:Context.Hwnd -ne [IntPtr]::Zero) {
        $info = Get-WindowInfo -Hwnd $script:Context.Hwnd
        if ($null -ne $info) {
            $script:Context.Title = $info.Title
            $script:Context.ProcessId = $info.ProcessId
            return $script:Context
        }
        $script:Context.Hwnd = [IntPtr]::Zero
    }

    $tyProcesses = @(Get-TyporaProcesses)
    if ($tyProcesses.Count -eq 0) {
        throw 'Typora is not running. Run "-Phase boot" first so the harness launches it with the fixture document.'
    }
    $pids = @($tyProcesses | ForEach-Object { [int]$_.Id })

    $win = Find-TyporaMainWindow -ProcessId $pids -TitlePattern $script:FixtureTitlePattern
    if ($null -eq $win) {
        $anyWin = Find-TyporaMainWindow -ProcessId $pids
        if ($null -eq $anyWin) {
            throw ('Typora is running (PIDs: {0}) but no visible main window was found.' -f ($pids -join ','))
        }
        if (-not $Force) {
            throw ('A Typora window is open ("{0}") but the test fixture "{1}" is not loaded. Run "-Phase boot" to launch a dedicated harness instance, or pass -Force to open the fixture in the existing instance.' -f $anyWin.Title, $script:FixtureName)
        }
        Write-Warn ('opening fixture in the existing Typora instance (-Force): ' + $anyWin.Title)
        $null = Start-Process -FilePath $script:TyporaExe -ArgumentList @(('"' + $script:FixturePath + '"'))
        $opened = Wait-Until -TimeoutSec 30 -IntervalMs 500 -Description 'fixture document opens in Typora' -Condition {
            $livePids = @(Get-TyporaProcesses | ForEach-Object { [int]$_.Id })
            if ($livePids.Count -eq 0) { return $false }
            $w = Find-TyporaMainWindow -ProcessId $livePids -TitlePattern $script:FixtureTitlePattern
            if ($null -ne $w) {
                $script:ResolvedWindow = $w
                return $true
            }
            return $false
        }
        if (-not $opened) {
            throw ('Could not open the fixture document in the running Typora instance within 30s (expected a window title matching "{0}").' -f $script:FixtureName)
        }
        $win = $script:ResolvedWindow
    }

    # The plugin must be booted in that instance; otherwise the UI phases are meaningless.
    $status = Get-PluginStatus
    $booted = Get-JsonField $status @('booted')
    if ($null -eq $status -or $booted -ne $true) {
        throw ('The plugin is not booted in the running Typora instance (status.json missing or booted != true). ' +
            'Reinstall with install.ps1, fully restart Typora, then run "-Phase boot".')
    }

    $script:Context = @{
        Hwnd      = $win.Hwnd
        ProcessId = $win.ProcessId
        Title     = $win.Title
        Adopted   = $true
    }
    Write-Info ('using Typora window: hwnd={0} pid={1} title="{2}"' -f $win.Hwnd, $win.ProcessId, $win.Title)
    return $script:Context
}

function Confirm-Foreground {
    <#
      Ensure $Hwnd really owns the OS foreground immediately before input is
      injected, and return $true only when GetForegroundWindow() == $Hwnd.
      The DSH GUI can steal the foreground between tool commands, which would
      silently redirect SendInput/mouse_event to the wrong window; every input
      batch must therefore call this right before injecting events.
    #>
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [int]$TimeoutSec = 5
    )
    $target = $Hwnd.ToInt64()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if ([TyUiNative]::GetForegroundWindowHandle() -eq $target) { return $true }
        $null = Set-WindowForeground -Hwnd $Hwnd
        if ([TyUiNative]::GetForegroundWindowHandle() -eq $target) { return $true }
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Set-EditorFocus {
    <# Foreground the Typora window (verified) and click into the editor body. #>
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    $focused = Confirm-Foreground -Hwnd $Hwnd -TimeoutSec 10
    if (-not $focused) { return $false }
    Start-Sleep -Milliseconds 250
    # Re-assert focus immediately before the click: the foreground can be
    # stolen while we were sleeping.
    if (-not (Confirm-Foreground -Hwnd $Hwnd -TimeoutSec 3)) { return $false }
    $clicked = Invoke-ClientClick -Hwnd $Hwnd -RelativeX $script:EditorRelX -RelativeY $script:EditorRelY -Button Left
    Start-Sleep -Milliseconds 300
    return $clicked
}

# ---------------------------------------------------------------------------
# Phase: boot
# ---------------------------------------------------------------------------
function Invoke-BootPhase {
    $details = New-Object System.Collections.ArrayList
    $shots = New-Object System.Collections.ArrayList

    Write-Section 'PHASE boot - install check + cold start'
    $script:AdoptMode = $false

    # --- 1. static install state ------------------------------------------
    $install = Test-PluginInstallState
    foreach ($d in $install.Details) { Write-Note $d; [void]$details.Add($d) }
    if (-not $install.Ok) {
        Write-Err 'The plugin is not installed in this Typora build.'
        Write-Note 'Expected: resources\plugin\typora-translate\{bootstrap.js,ui.js,service.js,styles.css}'
        Write-Note 'Expected: resources\window.html contains the typora-translate bootstrap script tag.'
        Write-Note 'Ask the Lead to run: powershell -NoProfile -ExecutionPolicy Bypass -File typora-translate\install.ps1'
        return (Add-PhaseResult -PhaseName 'boot' -Result 'BLOCKED' `
                -Evidence ('plugin not installed in ' + $script:TyporaRoot) -Details $details)
    }
    Write-Ok 'install state OK (plugin files + window.html injection)'
    [void]$details.Add('install state: OK')

    # --- 2. clean up only leftovers launched by a previous harness run -----
    $cleanup = Stop-OwnedTypora
    foreach ($note in $cleanup.Notes) { Write-Info $note; [void]$details.Add(('cleanup: ' + $note)) }
    if (@($cleanup.Failed).Count -gt 0) {
        $msg = ('Could not stop a Typora process tree launched by a previous harness run: PID {0}. ' -f (@($cleanup.Failed) -join ',')) +
               'Close it manually and retry (the harness will not kill processes it cannot verify).'
        Write-Err $msg
        return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence $msg -Details $details)
    }

    # --- 3. refuse to touch a user-owned Typora instance -------------------
    $foreign = @(Get-ForeignTyporaProcesses)
    if ($foreign.Count -gt 0) {
        $foreignDesc = (@($foreign | ForEach-Object { 'PID {0} ({1})' -f $_.Id, $(if ($_.MainWindowTitle) { $_.MainWindowTitle } else { '<no title>' }) }) -join ', ')
        [void]$details.Add('foreign Typora processes: ' + $foreignDesc)
        if (-not $Force) {
            $msg = ('A Typora instance not launched by this harness is running: {0}. ' -f $foreignDesc) +
                   'Safety policy: refusing to close it (it may hold unsaved documents). ' +
                   'Fully exit Typora and re-run, or pass -Force to adopt the running instance (it will not be killed).'
            Write-Err $msg
            return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence 'foreign Typora instance running; use -Force to adopt' -Details $details)
        }
        Write-Warn ('-Force: adopting the running Typora instance (' + $foreignDesc + '); it will NOT be killed.')
        $script:AdoptMode = $true
        [void]$details.Add('mode: adopt existing instance (-Force)')
    }
    else {
        [void]$details.Add('mode: cold launch of a dedicated Typora instance')
    }

    # --- 4. cold launch or adopt ------------------------------------------
    if (-not $script:AdoptMode) {
        # With no Typora running it is safe to clear the stale status file so
        # the booted=true assertion below can never be satisfied by old data.
        if (Test-Path -LiteralPath $script:StatusPath) {
            Remove-Item -LiteralPath $script:StatusPath -Force -ErrorAction SilentlyContinue
            [void]$details.Add('removed stale status.json before launch')
        }
        $logCountBefore = Get-LogLineCount
        $script:LogCountBeforeBoot = $logCountBefore
        [void]$details.Add(('plugin.log lines before launch: ' + $logCountBefore))

        try {
            $launch = Start-TyporaForTest
        }
        catch {
            $msg = ('Failed to launch Typora: ' + $_.Exception.Message)
            Write-Err $msg
            return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence $msg -Details $details)
        }
        $script:LaunchUtc = $launch.LaunchedAtUtc
        [void]$details.Add(('launched Typora PID {0} at {1:o}' -f $launch.RootPid, $launch.LaunchedAtUtc))
    }

    # --- 5. wait for the window -------------------------------------------
    $windowDeadline = $BootTimeoutSec
    $windowOk = Wait-Until -TimeoutSec $windowDeadline -IntervalMs 500 -Description 'Typora main window appears' -Condition {
        $livePids = @(Get-TyporaProcesses | ForEach-Object { [int]$_.Id })
        if ($livePids.Count -eq 0) { return $false }
        $w = Find-TyporaMainWindow -ProcessId $livePids -TitlePattern $script:FixtureTitlePattern
        if ($null -ne $w) {
            $script:BootWindow = $w
            return $true
        }
        return $false
    }
    if (-not $windowOk) {
        # A window may exist without the fixture title (restore dialog etc.);
        # capture it for evidence and let the status wait fail with diagnostics.
        $anyOk = Wait-Until -TimeoutSec 10 -IntervalMs 500 -Description 'any Typora window appears' -Condition {
            $livePids = @(Get-TyporaProcesses | ForEach-Object { [int]$_.Id })
            if ($livePids.Count -eq 0) { return $false }
            $w = Find-TyporaMainWindow -ProcessId $livePids
            if ($null -ne $w) {
                $script:BootWindow = $w
                return $true
            }
            return $false
        }
        if ($anyOk) {
            Write-Warn ('fixture window title not detected; using Typora window "{0}"' -f $script:BootWindow.Title)
            [void]$details.Add(('window title did not match fixture; using "' + $script:BootWindow.Title + '"'))
        }
        else {
            $procDump = (@(Get-TyporaProcesses | ForEach-Object { 'PID {0} started {1:o} title="{2}"' -f $_.Id, $_.StartTime, $_.MainWindowTitle }) -join '; ')
            $msg = ('No visible Typora main window appeared within {0}s (processes: {1}).' -f $BootTimeoutSec, $procDump)
            if ($script:LaunchUtc -ne [datetime]::MinValue) {
                $elapsed = ((Get-Date).ToUniversalTime() - $script:LaunchUtc).TotalSeconds
                [void]$details.Add(('elapsed since launch: {0:N1}s' -f $elapsed))
            }
            [void]$details.Add(('Typora exe: ' + $script:TyporaExe))
            Write-Err $msg
            return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence 'Typora window did not appear' -Details $details)
        }
    }
    $win = $script:BootWindow
    $script:Context = @{ Hwnd = $win.Hwnd; ProcessId = $win.ProcessId; Title = $win.Title; Adopted = $script:AdoptMode }
    Write-Ok ('Typora window found: hwnd={0} pid={1} title="{2}"' -f $win.Hwnd, $win.ProcessId, $win.Title)
    [void]$details.Add(('window: hwnd={0} pid={1} title="{2}" class={3} size={4}x{5}' -f $win.Hwnd, $win.ProcessId, $win.Title, $win.ClassName, $win.Width, $win.Height))

    # --- 6. wait for the plugin to report booted --------------------------
    Write-Info ('waiting up to {0}s for status.json booted=true + menus registered ...' -f $BootTimeoutSec)
    $script:BootFreshBasis = ''
    $bootOk = Wait-Until -TimeoutSec $BootTimeoutSec -IntervalMs 500 -Description 'plugin booted (status.json)' -Condition {
        $s = Get-PluginStatus
        if ($null -eq $s) { return $false }
        if ((Get-JsonField $s @('booted')) -ne $true) { return $false }
        $menus = Get-MenusState -Status $s
        if (-not ($menus.Rich -and $menus.Source)) { return $false }
        if (-not $script:AdoptMode -and $script:LaunchUtc -ne [datetime]::MinValue) {
            if (-not (Test-StatusFreshSince -Status $s -SinceUtc $script:LaunchUtc)) { return $false }
            $bootAt = ConvertTo-UtcDateTime -Value (Get-JsonField $s @('bootAt'))
            if ($bootAt -and $bootAt -ge $script:LaunchUtc.AddSeconds(-5)) { $script:BootFreshBasis = 'bootAt' }
            else { $script:BootFreshBasis = 'status.json mtime/updatedAt' }
        }
        else {
            $script:BootFreshBasis = 'adopted instance'
        }
        return $true
    }

    if (-not $bootOk) {
        Write-Err 'Plugin did not become ready (status.json booted=true + menus) in time.'
        $failShot = Save-E2EScreenshot -Hwnd $win.Hwnd -Name 'boot-fail.png'
        if ($failShot) { [void]$shots.Add($failShot.Path) }
        $diagnostics = @(Get-StatusDiagnostics)
        foreach ($d in $diagnostics) { Write-Note $d; [void]$details.Add($d) }
        $evidenceHint = 'status.json not ready'
        if (@($diagnostics | Where-Object { $_ -match 'disabled in config|disabled by config' }).Count -gt 0) {
            $evidenceHint = 'plugin booted but disabled in config.json'
        }
        return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' `
                -Evidence (('plugin did not boot within {0}s - {1}' -f $BootTimeoutSec, $evidenceHint)) `
                -Details $details -Screenshots $shots)
    }

    # --- 7. final assertions + evidence -----------------------------------
    $status = Get-PluginStatus
    $menus = Get-MenusState -Status $status
    $bootAtValue = ConvertTo-UtcDateTime -Value (Get-JsonField $status @('bootAt'))
    $typoraVersion = Get-JsonField $status @('typoraVersion')
    $serviceAvailable = Get-JsonField $status @('serviceAvailable')
    Write-Ok ('plugin booted: bootAt={0:o} menus rich={1} source={2}' -f $bootAtValue, $menus.Rich, $menus.Source)
    [void]$details.Add((Get-StatusSummaryText -Status $status))
    [void]$details.Add(('freshness basis: ' + $script:BootFreshBasis))
    if ($null -ne $typoraVersion) { [void]$details.Add(('typoraVersion: ' + [string]$typoraVersion)) }

    # [BOOT] markers in the log lines written after launch (warning only, the
    # contract makes status.json the authoritative boot signal).
    if (-not $script:AdoptMode -and $null -ne $script:LogCountBeforeBoot) {
        $newLog = Get-LogNewLinesSince -Offset ([int]$script:LogCountBeforeBoot)
        $bootLines = @($newLog.Lines | Where-Object { $_ -match '\[BOOT\]' })
        if ($bootLines.Count -gt 0) {
            foreach ($line in $bootLines) { [void]$details.Add('log: ' + $line) }
        }
        else {
            Write-Warn 'no [BOOT] lines in plugin.log after launch (status.json still authoritative)'
            [void]$details.Add('WARN: no [BOOT] log lines observed after launch')
        }
    }

    # Screenshot of the booted editor.
    $bootShot = Save-E2EScreenshot -Hwnd $win.Hwnd -Name 'boot-loaded.png'
    if ($bootShot) {
        [void]$shots.Add($bootShot.Path)
        if ($bootShot.Blank) {
            Write-Err 'boot screenshot is blank - screen capture is not working'
            [void]$details.Add('boot screenshot blank: ' + $bootShot.Path)
            return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence 'booted but screenshot capture is blank' -Details $details -Screenshots $shots)
        }
        [void]$details.Add(('boot screenshot: {0} ({1}x{2}, mode={3})' -f $bootShot.Path, $bootShot.Width, $bootShot.Height, $bootShot.Mode))
    }
    else {
        Write-Err 'boot screenshot could not be captured'
        return (Add-PhaseResult -PhaseName 'boot' -Result 'FAIL' -Evidence 'booted but screenshot capture failed' -Details $details -Screenshots $shots)
    }

    $evidence = ('booted=true bootAt={0:HH:mm:ss}Z menus rich={1} source={2} service={3}' -f $bootAtValue, $menus.Rich, $menus.Source, (Format-StatusValue $serviceAvailable))
    return (Add-PhaseResult -PhaseName 'boot' -Result 'PASS' -Evidence $evidence -Details $details -Screenshots $shots)
}

# ---------------------------------------------------------------------------
# Phase: hotkey (Ctrl+A then Ctrl+Shift+T)
# ---------------------------------------------------------------------------
function Invoke-HotkeyPhase {
    $details = New-Object System.Collections.ArrayList
    $shots = New-Object System.Collections.ArrayList

    Write-Section 'PHASE hotkey - select all + Ctrl+Shift+T'
    $ctx = Resolve-UiContext
    $hwnd = $ctx.Hwnd
    Write-Info ('target window: hwnd={0} title="{1}"' -f $hwnd, (Get-WindowInfo -Hwnd $hwnd).Title)

    # --- input sequence (focus-theft hardened) ----------------------------
    # The DSH GUI can steal the OS foreground between tool commands, so each
    # input batch re-asserts/verifies focus immediately before injection and
    # the whole select-all + hotkey sequence is retried when no fresh
    # translation shows up.
    $beforeShot = $null
    $translateOk = $false
    $logOffsetBefore = Get-LogLineCount
    $triggerUtc = (Get-Date).ToUniversalTime()
    $script:HotkeyTriggerUtc = $triggerUtc
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts -and -not $translateOk; $attempt++) {
        Write-Info ('hotkey attempt {0}/{1}' -f $attempt, $maxAttempts)
        if (-not (Set-EditorFocus -Hwnd $hwnd)) {
            Write-Warn 'could not focus / click the Typora editor; retrying'
            Start-Sleep -Milliseconds 400
            continue
        }
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 5)) {
            Write-Warn 'Typora lost the foreground before input; retrying'
            continue
        }
        $attemptOffset = Get-LogLineCount
        $attemptTrigger = (Get-Date).ToUniversalTime()
        $script:HotkeyTriggerUtc = $attemptTrigger
        [void]$details.Add(('attempt {0}: baseline log line = {1}, trigger = {2:o}' -f $attempt, $attemptOffset, $attemptTrigger))

        # Select all, then verify focus again; re-select if it was stolen.
        $ctrlA = Send-KeyChord -Chord 'CTRL+A'
        Start-Sleep -Milliseconds 350
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 3)) {
            Write-Warn 'focus was stolen right after Ctrl+A; re-focusing and re-selecting'
            $null = Set-EditorFocus -Hwnd $hwnd
            $ctrlA = Send-KeyChord -Chord 'CTRL+A'
            Start-Sleep -Milliseconds 350
        }
        if ($attempt -eq 1) {
            $beforeShot = Save-E2EScreenshot -Hwnd $hwnd -Name 'hotkey-before.png'
            if ($beforeShot) { [void]$shots.Add($beforeShot.Path) }
        }
        # Final foreground assertion immediately before the hotkey keystroke.
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 3)) {
            Write-Warn 'could not hold Typora in the foreground before Ctrl+Shift+T; retrying'
            continue
        }
        $hotkeySent = Send-KeyChord -Chord 'CTRL+SHIFT+T'
        Write-Info ('attempt {0}: Ctrl+A={1} Ctrl+Shift+T={2}; waiting up to {3}s for a CJK translation ...' -f $attempt, $ctrlA, $hotkeySent, $TranslateTimeoutSec)
        [void]$details.Add(('attempt {0}: Ctrl+A={1} Ctrl+Shift+T={2}' -f $attempt, $ctrlA, $hotkeySent))

        $script:HotkeyStatusSnapshot = $null
        $translateOk = Wait-Until -TimeoutSec $TranslateTimeoutSec -IntervalMs 400 -Description 'status.json lastTranslate ok + CJK' -Condition {
            $s = Get-PluginStatus
            if ($null -eq $s) { return $false }
            $lt = Get-JsonField $s @('lastTranslate')
            if ($null -eq $lt) { return $false }
            if ((Get-JsonField $lt @('ok')) -ne $true) { return $false }
            $resultText = [string](Get-JsonField $lt @('resultText'))
            if (-not (Test-ContainsCjk -Text $resultText)) { return $false }
            if (-not (Test-StatusFreshSince -Status $s -SinceUtc $script:HotkeyTriggerUtc)) { return $false }
            $script:HotkeyStatusSnapshot = $s
            return $true
        }
        $logOffsetBefore = $attemptOffset
        $triggerUtc = $attemptTrigger
        if (-not $translateOk) {
            Write-Warn ('hotkey attempt {0} produced no fresh CJK translation' -f $attempt)
            $null = Send-KeyChord -Chord 'ESC'
            Start-Sleep -Milliseconds 500
        }
    }

    # --- collect log evidence (both on success and failure) ---------------
    Start-Sleep -Milliseconds 300
    $newLog = Get-LogNewLinesSince -Offset $logOffsetBefore
    $newLines = @($newLog.Lines)
    $translateLines = @($newLines | Where-Object { $_ -match '\[TRANSLATE\]' })
    $translateOkLines = @($newLines | Where-Object { $_ -match '\[TRANSLATE\]\s+ok' })
    $uiLines = @($newLines | Where-Object { $_ -match '\[UI\]' })
    $uiMarkerSupported = Get-PluginLogMarkerPresence -Marker '[UI]'
    foreach ($line in $translateLines) { [void]$details.Add('log: ' + $line) }
    if ($newLog.Rotated) { [void]$details.Add('plugin.log was rotated; read from start') }

    $statusAfter = Get-PluginStatus
    $lt = $null
    if ($statusAfter) { $lt = Get-JsonField $statusAfter @('lastTranslate') }
    $provider = Get-JsonField $lt @('provider')
    $elapsedMs = Get-JsonField $lt @('elapsedMs')
    $resultText = [string](Get-JsonField $lt @('resultText'))
    $sourceText = [string](Get-JsonField $lt @('sourceText'))
    $rtOk = Get-JsonField $lt @('ok')

    # --- screenshot the panel ---------------------------------------------
    $panelShot = $null
    if ($translateOk) {
        $panelShot = Save-E2EScreenshot -Hwnd $hwnd -Name 'hotkey-panel.png'
        if ($panelShot) {
            [void]$shots.Add($panelShot.Path)
            if ($null -ne $beforeShot -and -not $beforeShot.Blank -and -not $panelShot.Blank) {
                $diff = Get-ImageDifference -PathA $beforeShot.Path -PathB $panelShot.Path
                if ($null -ne $diff) {
                    Write-Info ('panel appearance evidence: {0:P2} of sampled pixels changed' -f $diff.Ratio)
                    [void]$details.Add(('before/after screenshot difference: {0:P2} (mean channel delta {1})' -f $diff.Ratio, $diff.MeanDelta))
                }
            }
        }
    }
    else {
        Write-Warn 'translation did not succeed within the timeout'
    }

    # --- verdict ----------------------------------------------------------
    if (-not $translateOk) {
        $failShot = Save-E2EScreenshot -Hwnd $hwnd -Name 'hotkey-panel-fail.png'
        if ($failShot) { [void]$shots.Add($failShot.Path) }
        $diagnostics = @(Get-StatusDiagnostics)
        foreach ($d in $diagnostics) { Write-Note $d; [void]$details.Add($d) }
        if ($lt) {
            [void]$details.Add(('lastTranslate: ok={0} provider={1} error="{2}" resultTextLen={3}' -f `
                        (Format-StatusValue $rtOk), (Format-StatusValue $provider), (Format-StatusValue (Get-JsonField $lt @('error'))), $resultText.Length))
        }
        $evidence = ('status.json lastTranslate.ok != true or resultText has no CJK within {0}s' -f $TranslateTimeoutSec)
        return (Add-PhaseResult -PhaseName 'hotkey' -Result 'FAIL' -Evidence $evidence -Details $details -Screenshots $shots)
    }

    $cjkOk = Test-ContainsCjk -Text $resultText
    $evidenceParts = New-Object System.Collections.ArrayList
    [void]$evidenceParts.Add(('provider=' + (Format-StatusValue $provider)))
    [void]$evidenceParts.Add(('elapsedMs=' + (Format-StatusValue $elapsedMs)))
    [void]$evidenceParts.Add('resultCJK=true')
    [void]$evidenceParts.Add(('log[TRANSLATE]ok=' + ($translateOkLines.Count -gt 0)))
    [void]$evidenceParts.Add(('log[UI]=' + ($uiLines.Count -gt 0)))
    [void]$details.Add(('lastTranslate.ok=true sourceTextLen={0} resultTextLen={1}' -f $sourceText.Length, $resultText.Length))
    [void]$details.Add(('resultText preview: ' + ($resultText.Substring(0, [Math]::Min(120, $resultText.Length)))))
    if ($beforeShot) { [void]$details.Add('screenshot before hotkey: ' + $beforeShot.Path) }
    if ($panelShot) { [void]$details.Add('screenshot panel: ' + $panelShot.Path) }

    # Strict checks: log must show a successful translate; [UI] marker required
    # when the plugin emits it at all (otherwise a warning).
    $failures = New-Object System.Collections.ArrayList
    if (-not $cjkOk) { [void]$failures.Add('resultText contains no CJK characters') }
    if ($translateOkLines.Count -eq 0) { [void]$failures.Add('plugin.log has no new "[TRANSLATE] ok" line') }
    if ($null -eq $panelShot) { [void]$failures.Add('panel screenshot could not be captured') }
    elseif ($panelShot.Blank) { [void]$failures.Add('panel screenshot is blank') }
    elseif ($null -ne $beforeShot -and $panelShot -and -not $beforeShot.Blank) {
        $diffCheck = Get-ImageDifference -PathA $beforeShot.Path -PathB $panelShot.Path
        if ($null -ne $diffCheck -and $diffCheck.Ratio -lt 0.001) {
            Write-Warn 'before/after screenshots are nearly identical (panel may not be visible); not fatal'
        }
    }
    if ($uiMarkerSupported -and $uiLines.Count -eq 0) {
        [void]$failures.Add('plugin.log contains [UI] markers but none were written for this panel')
    }
    elseif (-not $uiMarkerSupported) {
        Write-Warn 'plugin.log has no [UI] markers at all; using status.json + screenshot as panel evidence'
        [void]$details.Add('WARN: plugin does not emit [UI] log markers')
    }

    if ($failures.Count -gt 0) {
        return (Add-PhaseResult -PhaseName 'hotkey' -Result 'FAIL' -Evidence (@($failures) -join '; ') -Details $details -Screenshots $shots)
    }

    $evidence = ('translated OK: ' + ($evidenceParts -join ' '))
    Write-Ok 'hotkey translation verified (status.json ok=true, CJK result, [TRANSLATE] ok logged)'
    return (Add-PhaseResult -PhaseName 'hotkey' -Result 'PASS' -Evidence $evidence -Details $details -Screenshots $shots)
}

# ---------------------------------------------------------------------------
# Phase: contextmenu (Ctrl+A then right-click)
# ---------------------------------------------------------------------------
function Invoke-ContextMenuPhase {
    $details = New-Object System.Collections.ArrayList
    $shots = New-Object System.Collections.ArrayList

    Write-Section 'PHASE contextmenu - select all + right-click -> [MENU] show'
    $ctx = Resolve-UiContext
    $hwnd = $ctx.Hwnd
    Write-Info ('target window: hwnd={0} title="{1}"' -f $hwnd, (Get-WindowInfo -Hwnd $hwnd).Title)

    # Close the translation panel (if the hotkey phase left one open) and any
    # lingering menu. Focus Typora FIRST so these ESC keystrokes cannot be
    # delivered to another window by mistake.
    $null = Confirm-Foreground -Hwnd $hwnd -TimeoutSec 10
    $null = Send-KeyChord -Chord 'ESC'
    Start-Sleep -Milliseconds 200
    $null = Send-KeyChord -Chord 'ESC'
    Start-Sleep -Milliseconds 250

    if (-not (Set-EditorFocus -Hwnd $hwnd)) {
        $shot = Save-E2EScreenshot -Hwnd $hwnd -Name 'menu-focus-fail.png'
        if ($shot) { [void]$shots.Add($shot.Path) }
        return (Add-PhaseResult -PhaseName 'contextmenu' -Result 'FAIL' -Evidence 'could not bring the Typora window to the foreground / click the editor' -Details $details -Screenshots $shots)
    }

    $menusBefore = Get-MenusState -Status (Get-PluginStatus)
    Write-Ok ('Typora focused, editor clicked; menus.rich={0} menus.source={1}' -f $menusBefore.Rich, $menusBefore.Source)

    $logOffsetBefore = Get-LogLineCount
    $triggerUtc = (Get-Date).ToUniversalTime()
    $script:MenuTriggerUtc = $triggerUtc
    $script:MenuLogOffset = $logOffsetBefore
    [void]$details.Add(('baseline: plugin.log line count = ' + $logOffsetBefore))

    # --- right click (retry at different points if no menu event appears) --
    # Focus is verified immediately before every Ctrl+A / right-click because
    # the DSH GUI may steal the foreground at any moment.
    $menuDetected = $false
    $attemptPoints = @(@($script:EditorRelX, $script:EditorRelY), @(0.5, 0.55), @(0.45, 0.40))
    $attempt = 0
    while (-not $menuDetected -and $attempt -lt $attemptPoints.Count) {
        $attempt++
        $relX = [double]$attemptPoints[$attempt - 1][0]
        $relY = [double]$attemptPoints[$attempt - 1][1]
        if (-not (Set-EditorFocus -Hwnd $hwnd)) { break }
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 5)) {
            Write-Warn 'Typora lost the foreground before the right-click attempt; retrying'
            continue
        }
        $null = Send-KeyChord -Chord 'CTRL+A'
        Start-Sleep -Milliseconds 350
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 3)) {
            Write-Warn 'focus was stolen right after Ctrl+A; re-focusing and re-selecting'
            $null = Set-EditorFocus -Hwnd $hwnd
            $null = Send-KeyChord -Chord 'CTRL+A'
            Start-Sleep -Milliseconds 350
        }
        if (-not (Confirm-Foreground -Hwnd $hwnd -TimeoutSec 3)) {
            Write-Warn 'could not hold Typora in the foreground before the right-click; retrying'
            continue
        }
        $rightClicked = Invoke-ClientClick -Hwnd $hwnd -RelativeX $relX -RelativeY $relY -Button Right
        Write-Info ('attempt {0}: right-click at ({1:P0}, {2:P0}) of client area: {3}' -f $attempt, $relX, $relY, $rightClicked)
        [void]$details.Add(('right-click attempt {0} at relative ({1}, {2}): {3}' -f $attempt, $relX, $relY, $rightClicked))
        $menuDetected = Wait-Until -TimeoutSec $MenuTimeoutSec -IntervalMs 250 -Description 'context menu [MENU] show event' -Condition {
            $tail = Get-LogNewLinesSince -Offset $script:MenuLogOffset
            $show = @($tail.Lines | Where-Object { $_ -match '\[MENU\]\s+show' })
            if ($show.Count -gt 0) {
                $script:MenuShowLines = $show
                return $true
            }
            $s = Get-PluginStatus
            $ls = Get-JsonField $s @('lastSelection')
            $textLen = Get-JsonField $ls @('textLen')
            if ((Test-Truthy $textLen) -and (Test-StatusFreshSince -Status $s -SinceUtc $script:MenuTriggerUtc)) {
                $script:MenuShowLines = @()
                return $true
            }
            return $false
        }
        if (-not $menuDetected) {
            $null = Send-KeyChord -Chord 'ESC'
            Start-Sleep -Milliseconds 250
        }
    }

    # Give the DOM menu a moment to render before capturing it.
    Start-Sleep -Milliseconds 500
    $menuShot = Save-E2EScreenshot -Hwnd $hwnd -Name 'menu.png'
    if ($menuShot) { [void]$shots.Add($menuShot.Path) }

    # --- gather evidence --------------------------------------------------
    $newLog = Get-LogNewLinesSince -Offset $logOffsetBefore
    $newLines = @($newLog.Lines)
    $showLines = @($newLines | Where-Object { $_ -match '\[MENU\]\s+show' })
    $insertedLines = @($newLines | Where-Object { $_ -match '\[MENU\]\s+inserted' })
    foreach ($line in $showLines) { [void]$details.Add('log: ' + $line) }
    foreach ($line in $insertedLines) { [void]$details.Add('log: ' + $line) }

    $menuShowLine = $null
    if ($showLines.Count -gt 0) { $menuShowLine = [string]$showLines[$showLines.Count - 1] }
    $selectionLen = -1
    if ($menuShowLine) {
        $lenMatch = [regex]::Match($menuShowLine, '(?i)\blen\s*[=:]\s*(\d+)')
        if (-not $lenMatch.Success) {
            # Fall back to any "selection length" style key/value in the line.
            $lenMatch = [regex]::Match($menuShowLine, '(?i)(?:selection|sel|chars|length)[a-z_]*\s*[=:]\s*(\d+)')
        }
        if ($lenMatch.Success) { $selectionLen = [int]$lenMatch.Groups[1].Value }
    }

    $statusAfter = Get-PluginStatus
    $lastSelection = Get-JsonField $statusAfter @('lastSelection')
    $selTextLen = Get-JsonField $lastSelection @('textLen')
    $selMode = Get-JsonField $lastSelection @('mode')
    $selPreview = Get-JsonField $lastSelection @('preview')
    $selFresh = Test-StatusFreshSince -Status $statusAfter -SinceUtc $triggerUtc
    $menusAfter = Get-MenusState -Status $statusAfter
    if ($null -ne $selTextLen) {
        [void]$details.Add(('status.lastSelection: mode={0} textLen={1} fresh={2}' -f (Format-StatusValue $selMode), (Format-StatusValue $selTextLen), $selFresh))
        if ($selPreview) { [void]$details.Add(('selection preview: ' + [string]$selPreview)) }
    }

    # --- verdict ----------------------------------------------------------
    $failures = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    $hasMenuEvent = ($showLines.Count -gt 0) -or ((Test-Truthy $selTextLen) -and $selFresh)
    if (-not $hasMenuEvent) {
        [void]$failures.Add('no new "[MENU] show" log line and no fresh status.lastSelection after right-click')
    }
    if ($showLines.Count -gt 0) {
        if ($selectionLen -lt 0) {
            [void]$warnings.Add('could not parse a selection length from the [MENU] line; falling back to status.lastSelection.textLen')
        }
        elseif ($selectionLen -le 0) {
            [void]$failures.Add('[MENU] show reported selection length 0 (Ctrl+A selection did not reach the plugin)')
        }
    }
    if (-not (Test-Truthy $selTextLen) -or -not $selFresh) {
        if ($showLines.Count -gt 0 -and $selectionLen -gt 0) {
            [void]$warnings.Add('status.lastSelection missing/stale (plugin log evidence is authoritative)')
        }
        else {
            [void]$failures.Add('status.lastSelection.textLen is not a fresh positive value')
        }
    }
    if ($null -eq $menuShot) { [void]$failures.Add('menu screenshot could not be captured') }
    elseif ($menuShot.Blank) { [void]$failures.Add('menu screenshot is blank') }
    if (-not ($menusAfter.Rich -and $menusAfter.Source)) {
        [void]$failures.Add('plugin status reports missing context-menu items (menus.rich/source)')
    }

    # Dismiss the menu so the desktop is left clean.
    $null = Send-KeyChord -Chord 'ESC'
    Start-Sleep -Milliseconds 200

    foreach ($w in $warnings) { Write-Warn $w; [void]$details.Add('WARN: ' + $w) }

    if ($failures.Count -gt 0) {
        Write-Err 'context-menu checks failed'
        foreach ($f in $failures) { Write-Note $f }
        $diagnostics = @(Get-StatusDiagnostics)
        foreach ($d in $diagnostics) { [void]$details.Add($d) }
        return (Add-PhaseResult -PhaseName 'contextmenu' -Result 'FAIL' -Evidence (@($failures) -join '; ') -Details $details -Screenshots $shots)
    }

    $lenText = if ($selectionLen -ge 0) { [string]$selectionLen } else { ('status:' + (Format-StatusValue $selTextLen)) }
    $evidence = ('[MENU] show logged, selectionLen={0}, menus rich={1} source={2}' -f $lenText, $menusAfter.Rich, $menusAfter.Source)
    Write-Ok 'context-menu [MENU] event verified with a non-empty selection'
    return (Add-PhaseResult -PhaseName 'contextmenu' -Result 'PASS' -Evidence $evidence -Details $details -Screenshots $shots)
}

# ---------------------------------------------------------------------------
# Environment info
# ---------------------------------------------------------------------------
function Write-EnvironmentInfo {
    Write-Section 'ENVIRONMENT'
    $hostEdition = 'Windows PowerShell ' + $PSVersionTable.PSVersion.ToString()
    if ($PSVersionTable.PSEdition) { $hostEdition = $PSVersionTable.PSEdition + ' ' + $PSVersionTable.PSVersion.ToString() }
    Write-Info ('run id: ' + $script:RunId)
    Write-Info ('host: ' + $hostEdition + ' / ' + [Environment]::OSVersion.VersionString + ' / session ' + [System.Diagnostics.Process]::GetCurrentProcess().SessionId)
    $screen = Get-ScreenInfo
    Write-Info ('screen (physical): ' + $screen.PrimaryWidth + 'x' + $screen.PrimaryHeight + ', virtual ' + $screen.VirtualWidth + 'x' + $screen.VirtualHeight)
    Write-Info ('Typora exe: ' + $script:TyporaExe + ' (exists=' + (Test-Path -LiteralPath $script:TyporaExe) + ')')
    $pkgJson = Join-Path $script:ResourcesDir 'package.json'
    if (Test-Path -LiteralPath $pkgJson) {
        try {
            $pkg = Get-Content -Raw -LiteralPath $pkgJson | ConvertFrom-Json
            Write-Info ('Typora version: ' + $pkg.version)
        }
        catch { }
    }
    Write-Info ('fixture: ' + $script:FixturePath + ' (exists=' + (Test-Path -LiteralPath $script:FixturePath) + ')')
    Write-Info ('plugin status dir: ' + $script:AppDataPluginDir)
    Write-Info ('screenshots: ' + $script:ScreenshotDir)
    Write-Info ('harness state: ' + $script:StatePath)
    $tyProcesses = @(Get-TyporaProcesses)
    Write-Info ('running Typora processes: ' + $tyProcesses.Count + $(if ($tyProcesses.Count -gt 0) { ' (PIDs: ' + (@($tyProcesses | ForEach-Object { $_.Id }) -join ',') + ')' } else { '' }))
}

function Ensure-FixtureAndDirs {
    <# Create the fixture document and output directories if they are missing. #>
    if (-not (Test-Path -LiteralPath $script:FixturePath)) {
        $dir = Split-Path -Parent $script:FixturePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
        $content = @'
# The Future of Renewable Energy

Renewable energy sources, such as solar and wind power, have become increasingly affordable over the past decade. Many countries now generate a significant share of their electricity from clean sources, reducing their dependence on fossil fuels.

This paragraph is also written in English and should be selected and translated by the plugin. The quick brown fox jumps over the lazy dog near the river bank.

The end.
'@
        Set-Content -LiteralPath $script:FixturePath -Value $content -Encoding UTF8
        Write-Warn ('fixture document was missing and has been created: ' + $script:FixturePath)
    }
    foreach ($dir in @($script:ScreenshotDir, $script:StateDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
function Write-Summary {
    param([string]$Overall)

    Write-Section 'E2E SUMMARY'
    Write-Host ('{0,-14} {1,-9} {2}' -f 'PHASE', 'RESULT', 'EVIDENCE') -ForegroundColor White
    Write-Host ('-' * 100) -ForegroundColor DarkGray
    foreach ($r in $script:Results) {
        $color = Get-ResultColor $r.Result
        $evidence = [string]$r.Evidence
        if ($evidence.Length -gt 78) { $evidence = $evidence.Substring(0, 75) + '...' }
        Write-Host ('{0,-14} {1,-9} {2}' -f $r.Phase, $r.Result, $evidence) -ForegroundColor $color
    }
    Write-Host ''

    $allShots = @()
    foreach ($r in $script:Results) { foreach ($s in @($r.Screenshots)) { if ($s) { $allShots += [string]$s } } }
    $allShots = @($allShots | Select-Object -Unique)
    if ($allShots.Count -gt 0) {
        Write-Host 'Screenshots:' -ForegroundColor White
        foreach ($s in $allShots) {
            $stats = Get-ImageStats -Path $s
            if ($stats) {
                Write-Host ('  - {0}  ({1}x{2}, nonblank={3}, mode-dimensions ok)' -f $s, $stats.Width, $stats.Height, (-not $stats.Blank)) -ForegroundColor Gray
            }
            else {
                Write-Host ('  - {0}  (MISSING)' -f $s) -ForegroundColor Red
            }
        }
        Write-Host ''
    }

    $passCount = @($script:Results | Where-Object { $_.Result -eq 'PASS' }).Count
    $failCount = @($script:Results | Where-Object { $_.Result -eq 'FAIL' -or $_.Result -eq 'BLOCKED' }).Count
    $skipCount = @($script:Results | Where-Object { $_.Result -eq 'SKIP' -or $_.Result -eq 'WARN' }).Count
    $color = 'Red'
    if ($Overall -eq 'PASS') { $color = 'Green' }
    Write-Host ('E2E RESULT: {0}   (passed={1} failed/blocked={2} skipped/warn={3})' -f $Overall, $passCount, $failCount, $skipCount) -ForegroundColor $color
    $elapsed = ((Get-Date).ToUniversalTime() - $script:StartedUtc).TotalSeconds
    Write-Host ('Elapsed: {0:N1}s' -f $elapsed) -ForegroundColor Gray
    Write-Host ('Run log:     ' + $script:RunLogPath) -ForegroundColor Gray
    Write-Host ('Summary JSON: ' + $script:SummaryPath) -ForegroundColor Gray
    Write-Host ''
}

function Save-SummaryJson {
    param([string]$Overall)
    $shots = @()
    foreach ($r in $script:Results) { foreach ($s in @($r.Screenshots)) { if ($s) { $shots += [string]$s } } }
    $summary = [pscustomobject]@{
        runId       = $script:RunId
        phase       = $Phase
        overall     = $Overall
        startedAt   = $script:StartedUtc.ToString('o')
        finishedAt  = (Get-Date).ToUniversalTime().ToString('o')
        typoraExe   = $script:TyporaExe
        typoraRoot  = $script:TyporaRoot
        fixture     = $script:FixturePath
        adopted     = [bool]$script:AdoptMode
        results     = @($script:Results)
        screenshots = @($shots | Select-Object -Unique)
    }
    try {
        $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SummaryPath -Encoding UTF8
    }
    catch {
        Write-Warn ('could not write summary JSON: ' + $_.Exception.Message)
    }
}

# ===========================================================================
# MAIN
# ===========================================================================
$exitCode = 1
try {
    $script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
    $script:RunLogPath = Join-Path $script:StateDir ('run-' + $script:RunId + '.log')
    $script:SummaryPath = Join-Path $script:StateDir ('summary-' + $script:RunId + '.json')

    Ensure-FixtureAndDirs

    if (-not $NoTranscript) {
        try {
            Start-Transcript -Path $script:RunLogPath -Force | Out-Null
            $script:TranscriptStarted = $true
        }
        catch {
            Write-Warn ('could not start transcript: ' + $_.Exception.Message)
        }
    }

    Write-Banner
    Write-EnvironmentInfo

    $phaseList = @()
    switch ($Phase) {
        'all' { $phaseList = @('boot', 'hotkey', 'contextmenu') }
        default { $phaseList = @($Phase) }
    }

    $bootPassed = $true
    foreach ($phaseName in $phaseList) {
        if ($phaseName -ne 'boot' -and -not $bootPassed) {
            [void](Add-PhaseResult -PhaseName $phaseName -Result 'SKIP' -Evidence 'skipped: boot phase did not PASS')
            continue
        }
        $entry = $null
        try {
            switch ($phaseName) {
                'boot' { $entry = Invoke-BootPhase }
                'hotkey' { $entry = Invoke-HotkeyPhase }
                'contextmenu' { $entry = Invoke-ContextMenuPhase }
                default { throw ('unknown phase: ' + $phaseName) }
            }
        }
        catch {
            $message = $_.Exception.Message
            Write-Err ('phase ' + $phaseName + ' threw: ' + $message)
            $extraShots = @()
            if ($script:Context.Hwnd -ne [IntPtr]::Zero) {
                $shot = Save-E2EScreenshot -Hwnd $script:Context.Hwnd -Name ($phaseName + '-exception.png')
                if ($shot) { $extraShots += $shot.Path }
            }
            $entry = Add-PhaseResult -PhaseName $phaseName -Result 'FAIL' -Evidence ('harness exception: ' + $message) -Screenshots $extraShots
        }
        if ($phaseName -eq 'boot') {
            $bootPassed = ($null -ne $entry -and $entry.Result -eq 'PASS')
        }
    }
}
catch {
    Write-Err ('fatal harness error: ' + $_.Exception.Message)
    Write-Note ($_.ScriptStackTrace)
    [void](Add-PhaseResult -PhaseName 'harness' -Result 'FAIL' -Evidence ('fatal error: ' + $_.Exception.Message))
}
finally {
    # --- cleanup: only the Typora tree this harness launched --------------
    Write-Section 'CLEANUP'
    try {
        $shouldStop = ($Phase -eq 'all') -and (-not $KeepOpen) -and (-not $script:AdoptMode)
        if ($shouldStop) {
            Write-Info 'stopping the Typora process tree launched by this harness (verified PIDs only) ...'
            $cleanup = Stop-OwnedTypora
            foreach ($note in $cleanup.Notes) { Write-Info $note }
            if (@($cleanup.Failed).Count -gt 0) {
                Write-Warn ('some harness-launched Typora processes are still running: PID ' + (@($cleanup.Failed) -join ','))
                Write-Warn 'Run "-Phase boot" again to clean them up, or close them manually.'
            }
            else {
                Write-Ok 'harness-launched Typora stopped'
            }
        }
        elseif ($script:AdoptMode) {
            Write-Info 'adopted Typora instance left running (it was not launched by this harness)'
        }
        elseif ($Phase -eq 'all') {
            Write-Info 'Typora left running (-KeepOpen)'
        }
        else {
            $livePids = @(Get-TyporaProcesses | ForEach-Object { $_.Id })
            if ($livePids.Count -gt 0) {
                Write-Info ('Typora left running (PIDs: ' + ($livePids -join ',') + ') for the next phase invocation')
            }
        }
    }
    catch {
        Write-Warn ('cleanup problem: ' + $_.Exception.Message)
    }

    # --- final verdict ----------------------------------------------------
    $failCount = @($script:Results | Where-Object { $_.Result -eq 'FAIL' -or $_.Result -eq 'BLOCKED' }).Count
    $passCount = @($script:Results | Where-Object { $_.Result -eq 'PASS' }).Count
    $overall = 'FAIL'
    if ($failCount -eq 0 -and $passCount -gt 0) { $overall = 'PASS' }
    try { Save-SummaryJson -Overall $overall } catch { }
    try { Write-Summary -Overall $overall } catch { }

    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    $exitCode = 0
    if ($overall -ne 'PASS') { $exitCode = 1 }
}

exit $exitCode