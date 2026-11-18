# =============================================================================
#  Typora Translate - installer
#  选中英文 -> 右键 -> 翻译 / Select English text -> right-click -> Translate
#
#  Usage (Windows PowerShell 5.1 or PowerShell 7):
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -TyporaPath "D:\Tools\Typora"
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -VerifyOnly
#
#  What it does:
#    1. locates the Typora installation (auto / explicit / registry / process),
#    2. copies the plugin into <Typora>\resources\plugin\typora-translate\,
#    3. injects one <script> tag into <Typora>\resources\window.html (backed up),
#    4. creates %APPDATA%\Typora\typora-translate\config.json on first install.
#
#  The patch is idempotent; run it again after every Typora upgrade.
# =============================================================================

[CmdletBinding()]
param(
    [string]$TyporaPath,
    [switch]$VerifyOnly,
    [switch]$NoConfig
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$pluginSrc = Join-Path $scriptDir 'src\plugin'
$configExample = Join-Path $scriptDir 'config\config.example.json'

$MarkerStart = '<!-- typora-translate:start -->'
$MarkerEnd   = '<!-- typora-translate:end -->'
$MarkerTag   = 'typora-translate-bootstrap'

function Write-Step([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [!!] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "  [XX] $Text" -ForegroundColor Red }

function Get-TyporaCandidatePaths {
    $list = New-Object System.Collections.Generic.List[string]
    if ($TyporaPath) { $list.Add($TyporaPath) }
    # 1. running process
    foreach ($p in @(Get-Process -Name 'Typora' -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $list.Add((Split-Path -Parent $p.Path)) } } catch {}
    }
    # 2. uninstall registry entries
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayName -like 'Typora*' -and $props.InstallLocation) {
                $list.Add(($props.InstallLocation.Trim('"') -replace '\\$', ''))
            }
        }
    }
    # 3. install metadata from a previous run
    $meta = Join-Path $env:APPDATA 'Typora\typora-translate\install.json'
    if (Test-Path $meta) {
        try {
            $json = Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.typoraPath) { $list.Add($json.typoraPath) }
        } catch {}
    }
    # 4. common locations
    $list.Add((Join-Path $env:ProgramFiles 'Typora'))
    if (${env:ProgramFiles(x86)}) { $list.Add((Join-Path ${env:ProgramFiles(x86)} 'Typora')) }
    if ($env:LOCALAPPDATA) { $list.Add((Join-Path $env:LOCALAPPDATA 'Programs\Typora')) }
    return $list
}

function Resolve-TyporaRoot {
    foreach ($candidate in (Get-TyporaCandidatePaths)) {
        if (-not $candidate) { continue }
        $dir = $candidate.Trim().TrimEnd('\')
        if (Test-Path (Join-Path $dir 'resources\window.html')) { return $dir }
    }
    return $null
}

function Test-PluginInstalled([string]$Root) {
    $pluginDir = Join-Path $Root 'resources\plugin\typora-translate'
    $windowHtml = Join-Path $Root 'resources\window.html'
    $filesOk = (Test-Path (Join-Path $pluginDir 'bootstrap.js')) -and
               (Test-Path (Join-Path $pluginDir 'ui.js')) -and
               (Test-Path (Join-Path $pluginDir 'service.js')) -and
               (Test-Path (Join-Path $pluginDir 'styles.css'))
    $injectedOk = $false
    if (Test-Path $windowHtml) {
        $text = [System.IO.File]::ReadAllText($windowHtml)
        $injectedOk = $text.Contains($MarkerStart) -and $text.Contains($MarkerTag)
    }
    return [pscustomobject]@{
        Root       = $Root
        PluginDir  = $pluginDir
        WindowHtml = $windowHtml
        FilesOk    = $filesOk
        InjectedOk = $injectedOk
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Typora Translate - Installer' -ForegroundColor Cyan
Write-Host '  选中英文 -> 右键 -> 翻译' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host ''

# --- sanity checks on the payload -----------------------------------------
$required = @('bootstrap.js', 'ui.js', 'service.js', 'styles.css')
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $pluginSrc $_)) })
if ($missing.Count -gt 0 -and -not $VerifyOnly) {
    Write-Err "插件文件不完整，缺少: $($missing -join ', ')"
    Write-Err "请确认 install.ps1 与 src\plugin 目录在同一项目文件夹中。"
    exit 1
}

# --- locate Typora ---------------------------------------------------------
Write-Step '正在查找 Typora 安装目录 ...'
$typoraRoot = Resolve-TyporaRoot
if (-not $typoraRoot) {
    Write-Err '未找到 Typora。请用 -TyporaPath 参数指定安装目录，例如:'
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -TyporaPath "D:\Tools\Typora"'
    exit 1
}
Write-Ok "Typora: $typoraRoot"

$resources = Join-Path $typoraRoot 'resources'
$windowHtml = Join-Path $resources 'window.html'
$typoraVersion = 'unknown'
$pkgJson = Join-Path $resources 'package.json'
if (Test-Path $pkgJson) {
    try { $typoraVersion = (Get-Content $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
}
Write-Step "Typora 版本: $typoraVersion"

$state = Test-PluginInstalled $typoraRoot
if ($VerifyOnly) {
    Write-Host ''
    Write-Step '安装状态:'
    Write-Step ("  插件文件:      " + $(if ($state.FilesOk) { '已安装' } else { '缺失' }))
    Write-Step ("  window.html:   " + $(if ($state.InjectedOk) { '已注入' } else { '未注入' }))
    $cfg = Join-Path $env:APPDATA 'Typora\typora-translate\config.json'
    Write-Step ("  配置文件:      " + $(if (Test-Path $cfg) { $cfg } else { '不存在（首次运行会创建）' }))
    if ($state.FilesOk -and $state.InjectedOk) { exit 0 } else { exit 1 }
}

# --- copy plugin files -----------------------------------------------------
$pluginDest = Join-Path $resources 'plugin\typora-translate'
Write-Step "复制插件文件 -> $pluginDest"
try {
    if (Test-Path $pluginDest) {
        # this directory is owned by the plugin: drop stale files from older versions
        Remove-Item $pluginDest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $pluginDest | Out-Null
    Copy-Item -Path (Join-Path $pluginSrc '*') -Destination $pluginDest -Recurse -Force
} catch {
    Write-Err "复制失败（可能是权限不足）: $($_.Exception.Message)"
    Write-Err "如果 Typora 安装在 Program Files，请以管理员身份重新运行。"
    exit 1
}
Write-Ok '插件文件已复制'

# --- patch window.html -----------------------------------------------------
Write-Step '注入加载脚本到 window.html ...'
$backup = "$windowHtml.typora-translate.bak"
try {
    $probeText = [System.IO.File]::ReadAllText($windowHtml)
    if (-not (Test-Path $backup)) {
        Copy-Item $windowHtml $backup -Force
        Write-Step "已备份原始文件: $backup"
    } elseif (-not $probeText.Contains($MarkerStart)) {
        # Typora was upgraded: window.html is pristine again but an old backup
        # from a previous Typora version still exists -> refresh it, otherwise
        # uninstall would restore a pre-upgrade window.html.
        Copy-Item $windowHtml $backup -Force
        Write-Step "检测到 Typora 更新（window.html 无插件标记），已刷新备份"
    }
    # preserve original BOM presence
    $bytes = [System.IO.File]::ReadAllBytes($windowHtml)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($windowHtml)
    # remove any previous block (idempotent re-install)
    $pattern = [regex]::Escape($MarkerStart) + '.*?' + [regex]::Escape($MarkerEnd)
    $text = [regex]::Replace($text, $pattern, '', 'Singleline')
    if ($text -notmatch '</body>') {
        throw 'window.html 结构不符合预期：找不到 </body>，可能 Typora 版本不兼容。'
    }
    $block = $MarkerStart + "`r`n" +
             '<script src="./plugin/typora-translate/bootstrap.js" id="' + $MarkerTag + '"></script>' + "`r`n" +
             $MarkerEnd + "`r`n"
    $idx = $text.LastIndexOf('</body>')
    $text = $text.Substring(0, $idx) + $block + $text.Substring($idx)
    $utf8 = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($windowHtml, $text, $utf8)
} catch {
    Write-Err "注入失败: $($_.Exception.Message)"
    Write-Err '已保留备份，原始 window.html 未被破坏。'
    exit 1
}
Write-Ok 'window.html 已注入'

# --- config ----------------------------------------------------------------
$appDir = Join-Path $env:APPDATA 'Typora\typora-translate'
$configPath = Join-Path $appDir 'config.json'
if (-not $NoConfig) {
    try {
        New-Item -ItemType Directory -Force -Path $appDir | Out-Null
        if (-not (Test-Path $configPath) -and (Test-Path $configExample)) {
            Copy-Item $configExample $configPath -Force
            Write-Ok "已创建配置文件: $configPath"
        } else {
            Write-Step "配置文件已存在: $configPath"
        }
    } catch {
        Write-Warn2 "配置文件创建失败（不影响使用）: $($_.Exception.Message)"
    }
}

# --- install metadata ------------------------------------------------------
try {
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    $meta = [ordered]@{
        typoraPath    = $typoraRoot
        typoraVersion = $typoraVersion
        pluginVersion = '1.0.0'
        installedAt   = (Get-Date).ToString('o')
    }
    $meta | ConvertTo-Json | Set-Content -Path (Join-Path $appDir 'install.json') -Encoding UTF8
} catch {}

# --- done ------------------------------------------------------------------
Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host ''
Write-Step '下一步: 完全退出 Typora（托盘图标也要退出），然后重新打开。'
Write-Step '使用方式: 选中一段英文 -> 右键 -> “翻译成中文”；或按 Ctrl+Shift+T。'
Write-Step "配置文件: $configPath"
Write-Step 'Typora 每次升级后需要重新运行本脚本（升级会覆盖 window.html）。'
Write-Host ''

# warn if Typora is running
$running = @(Get-Process -Name 'Typora' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Warn2 '检测到 Typora 正在运行：请完全退出后重新打开，插件才会生效。'
}
exit 0