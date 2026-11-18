# =============================================================================
#  Typora Translate - uninstaller
#
#  Usage (Windows PowerShell 5.1 or PowerShell 7):
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -TyporaPath "D:\Tools\Typora"
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeConfig
#
#  Restores resources/window.html from the pristine backup created by
#  install.ps1 (when possible), removes the plugin folder and metadata.
# =============================================================================

[CmdletBinding()]
param(
    [string]$TyporaPath,
    [switch]$PurgeConfig
)

$ErrorActionPreference = 'Stop'

$MarkerStart = '<!-- typora-translate:start -->'
$MarkerEnd   = '<!-- typora-translate:end -->'

function Write-Step([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [!!] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "  [XX] $Text" -ForegroundColor Red }

function Get-TyporaCandidatePaths {
    $list = New-Object System.Collections.Generic.List[string]
    if ($TyporaPath) { $list.Add($TyporaPath) }
    foreach ($p in @(Get-Process -Name 'Typora' -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $list.Add((Split-Path -Parent $p.Path)) } } catch {}
    }
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
    $meta = Join-Path $env:APPDATA 'Typora\typora-translate\install.json'
    if (Test-Path $meta) {
        try {
            $json = Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.typoraPath) { $list.Add($json.typoraPath) }
        } catch {}
    }
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

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Typora Translate - Uninstaller' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host ''

$typoraRoot = Resolve-TyporaRoot
if (-not $typoraRoot) {
    Write-Err '未找到 Typora 安装目录，请用 -TyporaPath 指定。'
    exit 1
}
Write-Step "Typora: $typoraRoot"

$windowHtml = Join-Path $typoraRoot 'resources\window.html'
$backup = "$windowHtml.typora-translate.bak"
$pluginDest = Join-Path $typoraRoot 'resources\plugin\typora-translate'

# --- restore window.html ---------------------------------------------------
try {
    if (Test-Path $windowHtml) {
        $bytes = [System.IO.File]::ReadAllBytes($windowHtml)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [System.IO.File]::ReadAllText($windowHtml)
        $pattern = [regex]::Escape($MarkerStart) + '.*?' + [regex]::Escape($MarkerEnd)
        $stripped = [regex]::Replace($text, $pattern, '', 'Singleline')
        $utf8 = New-Object System.Text.UTF8Encoding($hasBom)
        if (Test-Path $backup) {
            $original = [System.IO.File]::ReadAllText($backup)
            if ($stripped.TrimEnd() -eq $original.TrimEnd()) {
                [System.IO.File]::WriteAllText($windowHtml, $original, $utf8)
                Remove-Item $backup -Force
                Write-Ok 'window.html 已恢复为原始版本（来自备份）'
            } else {
                [System.IO.File]::WriteAllText($windowHtml, $stripped, $utf8)
                Write-Warn2 'window.html 有其他改动，已仅移除插件注入块（备份保留）'
            }
        } else {
            [System.IO.File]::WriteAllText($windowHtml, $stripped, $utf8)
            Write-Ok 'window.html 已移除插件注入块（无备份）'
        }
    }
} catch {
    Write-Err "恢复 window.html 失败: $($_.Exception.Message)"
}

# --- remove plugin files ---------------------------------------------------
try {
    if (Test-Path $pluginDest) {
        Remove-Item $pluginDest -Recurse -Force
        Write-Ok "已删除插件目录: $pluginDest"
    } else {
        Write-Step '插件目录不存在，跳过'
    }
} catch {
    Write-Err "删除插件目录失败: $($_.Exception.Message)"
}

# --- remove metadata / config ---------------------------------------------
$appDir = Join-Path $env:APPDATA 'Typora\typora-translate'
try {
    $meta = Join-Path $appDir 'install.json'
    if (Test-Path $meta) { Remove-Item $meta -Force }
    if ($PurgeConfig -and (Test-Path $appDir)) {
        Remove-Item $appDir -Recurse -Force
        Write-Ok "已删除配置与日志: $appDir"
    } elseif (Test-Path $appDir) {
        Write-Step "配置与日志保留在: $appDir（如需删除请加 -PurgeConfig）"
    }
} catch {}

Write-Host ''
Write-Host '卸载完成。请完全退出 Typora 后重新打开。' -ForegroundColor Green
Write-Host ''
exit 0