param(
    [string]$ModPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-EncodedFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    if ($hasBom) {
        $encoding = [System.Text.UTF8Encoding]::new($true, $true)
    } else {
        try {
            $null = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        } catch [System.Text.DecoderFallbackException] {
            $encoding = [System.Text.Encoding]::GetEncoding(936)
        }
    }
    $fileText = if ($hasBom) { $encoding.GetString($bytes, 3, $bytes.Length - 3) } else { $encoding.GetString($bytes) }
    return [pscustomobject]@{
        Path = $Path
        Bytes = $bytes
        Encoding = $encoding
        Text = $fileText
    }
}

function Set-ScriptBody([string]$Text, [string]$Name, [string]$Body) {
    $pattern = '(?m)^' + [regex]::Escape($Name) + ' -1[ \t]*\r?\n[^\r\n]*'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) { throw "找不到唯一脚本：$Name" }
    $match = $matches[0]
    $headerEnd = $match.Value.IndexOf("`n") + 1
    $replacement = $match.Value.Substring(0, $headerEnd) + $Body
    return $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
}

function Set-IniValue([string]$Text, [string]$Key, [string]$Value) {
    $pattern = '(?m)^(' + [regex]::Escape($Key) + '[ \t]*=[ \t]*)[^\s#]+'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) { throw "找不到唯一设置：$Key" }
    $match = $matches[0]
    $replacement = $match.Groups[1].Value + $Value
    return $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
}

$modRoot = [System.IO.Path]::GetFullPath($ModPath)
$required = @('scripts.txt', 'simple_triggers.txt', 'module.ini')
foreach ($relative in $required) {
    if (-not [System.IO.File]::Exists((Join-Path $modRoot $relative))) {
        throw "缺少文件：$relative；请指定潘德子 MOD 的根目录。"
    }
}

$scripts = Read-EncodedFile (Join-Path $modRoot 'scripts.txt')
$triggers = Read-EncodedFile (Join-Path $modRoot 'simple_triggers.txt')
$ini = Read-EncodedFile (Join-Path $modRoot 'module.ini')
$uiPath = Join-Path $modRoot 'languages\cns\ui.csv'
$ui = if ([System.IO.File]::Exists($uiPath)) { Read-EncodedFile $uiPath } else { $null }

# Compiled Warband script identifiers are the script list position plus this base.
$scriptMatches = [regex]::Matches($scripts.Text, '(?m)^([A-Za-z_][A-Za-z0-9_]*) -1[ \t]*\r?$')
$declaredCount = [int](($scripts.Text -split '\r?\n', 4)[1].Trim())
if ($scriptMatches.Count -ne $declaredCount) {
    throw "scripts.txt 脚本数不一致：声明 $declaredCount，实际 $($scriptMatches.Count)。"
}
$scriptNames = @($scriptMatches | ForEach-Object { $_.Groups[1].Value })
$autoIndex = [array]::IndexOf($scriptNames, 'start_auto_point')
if ($autoIndex -lt 0) { throw '未找到新加点系统；此包只适用于含有该系统的模组。' }
$autoId = [long]936748722493063168 + $autoIndex

$troop = '1224979098644774912'
$amount = '1224979098644774913'
$scriptText = $scripts.Text
$scriptText = Set-ScriptBody $scriptText 'store_intelligence_attribute_level' " 2 23 2 $troop 1 2172 3 72057594037927936 $troop 2 "
$scriptText = Set-ScriptBody $scriptText 'raise_intelligence_attribute_level' " 3 23 2 $troop 1 23 2 $amount 2 1520 3 $troop 2 $amount "
$scriptText = Set-ScriptBody $scriptText 'calculate_available_points' ' 0 '
$scriptText = Set-ScriptBody $scriptText 'start_auto_point' ' 0 '
if ([array]::IndexOf($scriptNames, 'game_character_screen_requested') -ge 0) {
    $scriptText = Set-ScriptBody $scriptText 'game_character_screen_requested' ' 1 2075 1 0 '
}

$afterCount = [regex]::Matches($scriptText, '(?m)^([A-Za-z_][A-Za-z0-9_]*) -1[ \t]*\r?$').Count
if ($afterCount -ne $declaredCount) { throw '修改后脚本数量变化，已停止。' }

$iniText = Set-IniValue $ini.Text 'skill_points_per_level' '1'
$iniText = Set-IniValue $iniText 'attribute_points_per_level' '1'
$iniText = Set-IniValue $iniText 'weapon_points_per_level' '10'

$triggerText = $triggers.Text
$triggerPattern = '(?m)^24\.000000[ \t]+1[ \t]+1[ \t]+1[ \t]+' + [regex]::Escape([string]$autoId) + '[ \t]*(?<cr>\r?)$'
$triggerMatches = [regex]::Matches($triggerText, $triggerPattern)
if ($triggerMatches.Count -gt 1) { throw '找到多个每日自动加点触发器，已停止。' }
if ($triggerMatches.Count -eq 1) {
    $match = $triggerMatches[0]
    $triggerText = $triggerText.Substring(0, $match.Index) + '24.000000  0 ' + $match.Groups['cr'].Value + $triggerText.Substring($match.Index + $match.Length)
}

$updates = @(
    [pscustomobject]@{ File = $scripts; Text = $scriptText; Relative = 'scripts.txt' },
    [pscustomobject]@{ File = $triggers; Text = $triggerText; Relative = 'simple_triggers.txt' },
    [pscustomobject]@{ File = $ini; Text = $iniText; Relative = 'module.ini' }
)
if ($null -ne $ui) {
    $uiMatches = [regex]::Matches($ui.Text, '(?m)^ui_int\|[^\r\n]*')
    if ($uiMatches.Count -ne 1) { throw '简体中文 ui.csv 中找不到唯一的 ui_int 项。' }
    $match = $uiMatches[0]
    $uiText = $ui.Text.Substring(0, $match.Index) + 'ui_int|智 ' + $ui.Text.Substring($match.Index + $match.Length)
    $updates += [pscustomobject]@{ File = $ui; Text = $uiText; Relative = 'languages\cns\ui.csv' }
}

$changed = @($updates | Where-Object { $_.File.Text -cne $_.Text })
Write-Host "模组：$modRoot"
Write-Host "自动加点脚本编号：$autoId；需要修改的文件数：$($changed.Count)"
if ($CheckOnly) {
    Write-Host '检查完成，未写入文件。'
    exit 0
}
if ($changed.Count -eq 0) {
    Write-Host '已经是目标状态，无需再次修改。'
    exit 0
}

$backupDir = Join-Path $modRoot ('_原版加点备份_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
[System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
$written = @()
try {
    foreach ($item in $changed) {
        $backupPath = Join-Path $backupDir $item.Relative
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($backupPath)) | Out-Null
        [System.IO.File]::WriteAllBytes($backupPath, $item.File.Bytes)
    }
    foreach ($item in $changed) {
        $written += $item
        [System.IO.File]::WriteAllText($item.File.Path, $item.Text, $item.File.Encoding)
        Write-Host "已修改：$($item.Relative)"
    }
} catch {
    foreach ($item in $written) {
        [System.IO.File]::WriteAllBytes($item.File.Path, $item.File.Bytes)
    }
    throw
}
Write-Host "完成。原文件备份：$backupDir"
