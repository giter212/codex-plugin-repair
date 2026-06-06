[CmdletBinding()]
param(
  [switch]$SelfTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

$script:ToolName = 'codex computeruse与chrome插件维修'
$script:CodexRoot = Join-Path $env:USERPROFILE '.codex'
$script:OpenAIBundledCache = Join-Path $script:CodexRoot 'plugins\cache\openai-bundled'
$script:OpenAIBundledMarketplace = Join-Path $script:CodexRoot '.tmp\bundled-marketplaces\openai-bundled'
$script:NativeHostName = 'com.openai.codexextension'
$script:ExtensionId = 'hehggadaopoacecdllhhajmbjkdcmajg'
$script:NativeHostManifest = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
$script:ChromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'

function New-StatusItem {
  param(
    [string]$Name,
    [string]$State,
    [string]$Detail
  )

  [pscustomobject]@{
    Name = $Name
    State = $State
    Detail = $Detail
  }
}

function Test-File {
  param([string]$Path)
  return [System.IO.File]::Exists($Path)
}

function Test-Dir {
  param([string]$Path)
  return [System.IO.Directory]::Exists($Path)
}

function Get-LatestPluginVersionPath {
  param(
    [Parameter(Mandatory = $true)][string]$PluginName
  )

  $pluginRoot = Join-Path $script:OpenAIBundledCache $PluginName
  if (-not (Test-Dir $pluginRoot)) {
    return $null
  }

  $versions = Get-ChildItem -LiteralPath $pluginRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object Name -Descending

  if ($versions.Count -gt 0) {
    return $versions[0].FullName
  }

  return $null
}

function Test-MarketplacePlugin {
  param(
    [Parameter(Mandatory = $true)][string]$PluginName,
    [Parameter(Mandatory = $true)][string[]]$RequiredRelativePaths
  )

  $pluginRoot = Join-Path (Join-Path $script:OpenAIBundledMarketplace 'plugins') $PluginName
  if (-not (Test-Dir $pluginRoot)) {
    return New-StatusItem "marketplace/$PluginName" '缺失' "未找到 $pluginRoot"
  }

  $missing = New-Object System.Collections.Generic.List[string]
  $pluginJson = Join-Path $pluginRoot '.codex-plugin\plugin.json'
  if (-not (Test-File $pluginJson)) {
    $missing.Add('.codex-plugin\plugin.json')
  }

  foreach ($relativePath in $RequiredRelativePaths) {
    $fullPath = Join-Path $pluginRoot $relativePath
    if (-not (Test-File $fullPath)) {
      $missing.Add($relativePath)
    }
  }

  if ($missing.Count -gt 0) {
    return New-StatusItem "marketplace/$PluginName" '异常' ("缺少：`r`n" + ($missing -join "`r`n"))
  }

  return New-StatusItem "marketplace/$PluginName" '正常' "marketplace 源插件完整：$pluginRoot"
}

function Get-CodexInstallCandidates {
  $candidates = New-Object System.Collections.Generic.List[string]

  Get-Process -Name 'Codex','codex' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      if ($_.Path) {
        $candidates.Add($_.Path)
      }
    } catch {
    }
  }

  $uninstallRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )

  foreach ($root in $uninstallRoots) {
    if (-not (Test-Path $root)) {
      continue
    }

    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $item = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
      if ($item.DisplayName -match 'Codex|OpenAI') {
        foreach ($field in @('InstallLocation', 'DisplayIcon', 'UninstallString')) {
          if ($item.$field) {
            $candidates.Add([string]$item.$field)
          }
        }
      }
    }
  }

  foreach ($packagePattern in @('*Codex*', '*OpenAI*')) {
    try {
      Get-AppxPackage -Name $packagePattern -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.InstallLocation) {
          $candidates.Add($_.InstallLocation)
        }
      }
    } catch {
    }
  }

  return $candidates | Where-Object { $_ } | Select-Object -Unique
}

function Get-CodexInstallStatus {
  $paths = @(Get-CodexInstallCandidates)
  if ($paths.Count -eq 0) {
    return New-StatusItem 'Codex 安装位置' '未知' '未从进程、卸载注册表或 Appx 包中识别到 Codex 安装路径。'
  }

  $nonC = @($paths | Where-Object { $_ -notmatch '^[Cc]:' })
  if ($nonC.Count -gt 0) {
    return New-StatusItem 'Codex 安装位置' '警告' ("发现疑似非 C 盘路径：`r`n" + ($nonC -join "`r`n"))
  }

  return New-StatusItem 'Codex 安装位置' '正常' ("检测到 Codex 路径在 C 盘：`r`n" + (($paths | Select-Object -First 5) -join "`r`n"))
}

function Find-ExtensionInstallPaths {
  param([string]$BrowserUserData)

  if (-not (Test-Dir $BrowserUserData)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $BrowserUserData -Recurse -Directory -Filter $script:ExtensionId -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*\Extensions\*' } |
    Select-Object -ExpandProperty FullName)
}

function Get-NativeHostRegistryPath {
  $registryPath = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$script:NativeHostName"

  try {
    $item = Get-Item -LiteralPath $registryPath -ErrorAction Stop
    return [string]$item.GetValue('')
  } catch {
    return $null
  }
}

function Test-NativeHostManifest {
  if (-not (Test-File $script:NativeHostManifest)) {
    return New-StatusItem '浏览器 native host manifest' '缺失' "未找到 $script:NativeHostManifest"
  }

  try {
    $json = Get-Content -LiteralPath $script:NativeHostManifest -Raw | ConvertFrom-Json
    $expectedOrigin = "chrome-extension://$script:ExtensionId/"
    $originOk = @($json.allowed_origins) -contains $expectedOrigin
    $pathOk = $json.path -and (Test-File ([string]$json.path))
    $nameOk = $json.name -eq $script:NativeHostName

    if ($originOk -and $pathOk -and $nameOk) {
      return New-StatusItem '浏览器 native host manifest' '正常' "manifest 存在，扩展 ID 和 extension-host 路径正确。"
    }

    return New-StatusItem '浏览器 native host manifest' '异常' "manifest 存在，但 name/origin/path 不完整或 extension-host 不存在。"
  } catch {
    return New-StatusItem '浏览器 native host manifest' '异常' "manifest 不是有效 JSON：$($_.Exception.Message)"
  }
}

function Get-PluginStatus {
  $items = New-Object System.Collections.Generic.List[object]

  if (Test-Dir $script:OpenAIBundledCache) {
    $items.Add((New-StatusItem 'bundled 插件缓存' '正常' $script:OpenAIBundledCache))
  } else {
    $items.Add((New-StatusItem 'bundled 插件缓存' '缺失' $script:OpenAIBundledCache))
  }

  if (Test-Dir $script:OpenAIBundledMarketplace) {
    $items.Add((New-StatusItem 'bundled marketplace 缓存' '正常' $script:OpenAIBundledMarketplace))
  } else {
    $items.Add((New-StatusItem 'bundled marketplace 缓存' '缺失' $script:OpenAIBundledMarketplace))
  }

  $items.Add((Test-MarketplacePlugin 'chrome' @(
    'scripts\browser-client.mjs',
    'scripts\check-extension-installed.js',
    'scripts\open-chrome-window.js'
  )))
  $items.Add((Test-MarketplacePlugin 'computer-use' @(
    'scripts\computer-use-client.mjs'
  )))

  $chromePath = Get-LatestPluginVersionPath 'chrome'
  if ($chromePath) {
    $chromePluginJson = Join-Path $chromePath '.codex-plugin\plugin.json'
    $chromeClient = Join-Path $chromePath 'scripts\browser-client.mjs'
    if ((Test-File $chromePluginJson) -and (Test-File $chromeClient)) {
      $items.Add((New-StatusItem '浏览器控制插件包' '正常' "plugin.json 和 browser-client.mjs 均存在：$chromePath"))
    } elseif (Test-File $chromeClient) {
      $items.Add((New-StatusItem '浏览器控制插件包' '异常' "browser-client.mjs 存在，但 .codex-plugin\plugin.json 缺失：$chromePath"))
    } else {
      $items.Add((New-StatusItem '浏览器控制插件包' '异常' "浏览器控制插件目录存在，但关键脚本缺失：$chromePath"))
    }
  } else {
    $items.Add((New-StatusItem '浏览器控制插件包' '缺失' '未找到 openai-bundled\chrome 的版本目录。'))
  }

  $computerUsePath = Get-LatestPluginVersionPath 'computer-use'
  if ($computerUsePath) {
    $computerPluginJson = Join-Path $computerUsePath '.codex-plugin\plugin.json'
    $computerClient = Join-Path $computerUsePath 'scripts\computer-use-client.mjs'
    if ((Test-File $computerPluginJson) -and (Test-File $computerClient)) {
      $items.Add((New-StatusItem 'Computer Use 插件包' '正常' "plugin.json 和 computer-use-client.mjs 均存在：$computerUsePath"))
    } else {
      $items.Add((New-StatusItem 'Computer Use 插件包' '异常' "缺少 plugin.json 或 computer-use-client.mjs：$computerUsePath"))
    }
  } else {
    $items.Add((New-StatusItem 'Computer Use 插件包' '缺失' '未找到 openai-bundled\computer-use 的版本目录。'))
  }

  $chromeReg = Get-NativeHostRegistryPath
  if ($chromeReg) {
    $items.Add((New-StatusItem '浏览器 native host 注册表' '正常' $chromeReg))
  } else {
    $items.Add((New-StatusItem '浏览器 native host 注册表' '缺失' "HKCU\Software\Google\Chrome\NativeMessagingHosts\$script:NativeHostName"))
  }

  $items.Add((Test-NativeHostManifest))

  $chromeExtensions = @(Find-ExtensionInstallPaths $script:ChromeUserData)
  if ($chromeExtensions.Count -gt 0) {
    $items.Add((New-StatusItem '浏览器扩展安装' '正常' ($chromeExtensions -join "`r`n")))
  } else {
    $items.Add((New-StatusItem '浏览器扩展安装' '缺失' "未在 Chrome User Data 中找到 $script:ExtensionId"))
  }

  $items.Add((Get-CodexInstallStatus))

  return $items.ToArray()
}

function Test-NeedsRepair {
  param([array]$Items)

  return @($Items | Where-Object { $_.State -in @('缺失', '异常') }).Count -gt 0
}

function Stop-ExtensionHost {
  $stopped = New-Object System.Collections.Generic.List[string]
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -eq 'extension-host.exe' -and
      $_.ExecutablePath -like "$script:CodexRoot*openai-bundled*extension-host.exe"
    } |
    ForEach-Object {
      try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
        $stopped.Add("PID $($_.ProcessId)")
      } catch {
        $stopped.Add("PID $($_.ProcessId) 停止失败：$($_.Exception.Message)")
      }
    }

  return $stopped
}

function Test-CodexOrChromeRunning {
  $names = @('Codex', 'codex', 'chrome')
  $running = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
  return $running
}

function Remove-StagingFolders {
  $details = New-Object System.Collections.Generic.List[string]
  $marketplacesTmp = Join-Path $script:CodexRoot '.tmp\bundled-marketplaces'
  if (Test-Dir $marketplacesTmp) {
    $stagedFolders = Get-ChildItem -LiteralPath $marketplacesTmp -Directory -Filter "staging-*" -ErrorAction SilentlyContinue
    foreach ($folder in $stagedFolders) {
      try {
        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
        $details.Add("已清理残留部署目录：$($folder.Name)")
      } catch {
        $details.Add("清理残留部署目录失败：$($folder.Name) - $($_.Exception.Message)")
      }
    }
  }
  return $details
}

function Move-CodexPluginCacheToBackup {
  $resolvedCodex = (Resolve-Path -LiteralPath $script:CodexRoot).Path
  $backupRoot = Join-Path $script:CodexRoot ('backups\plugin-cache-refresh-gui-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

  $moves = @(
    @{ From = $script:OpenAIBundledCache; To = (Join-Path $backupRoot 'plugins-cache-openai-bundled') },
    @{ From = $script:OpenAIBundledMarketplace; To = (Join-Path $backupRoot 'tmp-bundled-marketplace-openai-bundled') }
  )

  $details = New-Object System.Collections.Generic.List[string]
  foreach ($move in $moves) {
    if (-not (Test-Path -LiteralPath $move.From)) {
      $details.Add("跳过不存在路径：$($move.From)")
      continue
    }

    $resolvedFrom = (Resolve-Path -LiteralPath $move.From).Path
    if (-not $resolvedFrom.StartsWith($resolvedCodex, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "拒绝移动 Codex 根目录之外的路径：$resolvedFrom"
    }

    Move-Item -LiteralPath $resolvedFrom -Destination $move.To
    $details.Add("已移动：$resolvedFrom -> $($move.To)")
  }

  $details.Add("备份目录：$backupRoot")
  return $details
}

function Invoke-Repair {
  $running = @(Test-CodexOrChromeRunning)
  if ($running.Count -gt 0) {
    $runningText = $running -join ', '
    [System.Windows.Forms.MessageBox]::Show(
      "检测到仍在运行：$runningText`r`n`r`n请完全退出 Codex 和浏览器后再点击维修。",
      '需要先退出程序',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return "维修未执行：Codex 或浏览器仍在运行。"
  }

  $stopped = Stop-ExtensionHost
  $moved = Move-CodexPluginCacheToBackup
  $cleaned = Remove-StagingFolders
  $summary = New-Object System.Collections.Generic.List[string]
  if ($stopped.Count -gt 0) {
    $summary.Add('已停止 extension-host：')
    $stopped | ForEach-Object { $summary.Add("  $_") }
  }
  $summary.Add('已处理缓存目录（Codex 下次启动会重新生成）：')
  $moved | ForEach-Object { $summary.Add("  $_") }
  if ($cleaned.Count -gt 0) {
    $cleaned | ForEach-Object { $summary.Add("  $_") }
  }
  $summary.Add('')
  $summary.Add('下一步：重新打开 Codex，然后回到 Plugins/Computer Use 页面检查。')
  return ($summary -join "`r`n")
}

function Open-InstalledAppsSettings {
  Start-Process 'ms-settings:appsfeatures'
}

function Format-StatusText {
  param([array]$Items)

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Items) {
    $lines.Add("[$($item.State)] $($item.Name)")
    if ($item.Detail) {
      $lines.Add("  $($item.Detail)")
    }
    $lines.Add('')
  }

  if (Test-NeedsRepair $Items) {
    $lines.Add('结论：检测到缺失或异常。建议先完全退出 Codex 和浏览器，再点击 [开始维修]。')
  } else {
    $lines.Add('结论：本地插件包和关键注册项看起来正常。若 Codex 内仍不可用，优先重启 Codex；仍失败再尝试维修。')
  }

  return ($lines -join "`r`n")
}

$null = [System.Windows.Forms.Application]::EnableVisualStyles()

$script:Colors = @{
  Window = [System.Drawing.ColorTranslator]::FromHtml('#F5F6F2')
  Surface = [System.Drawing.ColorTranslator]::FromHtml('#FBFBF8')
  Border = [System.Drawing.ColorTranslator]::FromHtml('#D8DCD3')
  Text = [System.Drawing.ColorTranslator]::FromHtml('#20231F')
  Muted = [System.Drawing.ColorTranslator]::FromHtml('#5F685C')
  Accent = [System.Drawing.ColorTranslator]::FromHtml('#2F6F5E')
  AccentSoft = [System.Drawing.ColorTranslator]::FromHtml('#E3F0EA')
  WarningSoft = [System.Drawing.ColorTranslator]::FromHtml('#FFF1D7')
  WarningText = [System.Drawing.ColorTranslator]::FromHtml('#855A10')
  ErrorSoft = [System.Drawing.ColorTranslator]::FromHtml('#F8E1DE')
  ErrorText = [System.Drawing.ColorTranslator]::FromHtml('#9A2E24')
  OkSoft = [System.Drawing.ColorTranslator]::FromHtml('#E7F3E4')
  OkText = [System.Drawing.ColorTranslator]::FromHtml('#27613C')
}

function New-UiFont {
  param(
    [float]$Size,
    [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
  )
  return New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $Style)
}

function Set-FlatButtonStyle {
  param(
    [System.Windows.Forms.Button]$Button,
    [bool]$Primary = $false
  )

  $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $Button.FlatAppearance.BorderSize = 1
  $Button.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)
  $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
  if ($Primary) {
    $Button.BackColor = $script:Colors.Accent
    $Button.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCF8')
    $Button.FlatAppearance.BorderColor = $script:Colors.Accent
  } else {
    $Button.BackColor = $script:Colors.Surface
    $Button.ForeColor = $script:Colors.Text
    $Button.FlatAppearance.BorderColor = $script:Colors.Border
  }
}

function Get-OverallState {
  param([array]$Items)

  if (@($Items | Where-Object { $_.State -in @('缺失', '异常') }).Count -gt 0) {
    return '需要维修'
  }
  if (@($Items | Where-Object { $_.State -eq '警告' }).Count -gt 0) {
    return '有提示'
  }
  if (@($Items | Where-Object { $_.State -eq '未知' }).Count -gt 0) {
    return '需确认'
  }
  return '正常'
}

function Get-StatePalette {
  param([string]$State)

  switch ($State) {
    '正常' { return @{ Back = $script:Colors.OkSoft; Fore = $script:Colors.OkText } }
    '警告' { return @{ Back = $script:Colors.WarningSoft; Fore = $script:Colors.WarningText } }
    '未知' { return @{ Back = $script:Colors.WarningSoft; Fore = $script:Colors.WarningText } }
    '需要维修' { return @{ Back = $script:Colors.ErrorSoft; Fore = $script:Colors.ErrorText } }
    '缺失' { return @{ Back = $script:Colors.ErrorSoft; Fore = $script:Colors.ErrorText } }
    '异常' { return @{ Back = $script:Colors.ErrorSoft; Fore = $script:Colors.ErrorText } }
    default { return @{ Back = $script:Colors.Surface; Fore = $script:Colors.Text } }
  }
}

if ($SelfTest) {
  $items = @(Get-PluginStatus)
  $result = [pscustomobject]@{
    ok = $true
    overallState = Get-OverallState $items
    itemCount = $items.Count
    items = $items
  }
  $result | ConvertTo-Json -Depth 5
  return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:ToolName
$form.Size = New-Object System.Drawing.Size(940, 660)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(860, 580)
$form.BackColor = $script:Colors.Window
$form.Font = New-UiFont 9

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(18, 16)
$headerPanel.Size = New-Object System.Drawing.Size(888, 42)
$headerPanel.Anchor = 'Top, Left, Right'
$headerPanel.BackColor = $script:Colors.Window
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $script:ToolName
$titleLabel.Font = New-UiFont 18 ([System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $script:Colors.Text
$titleLabel.Location = New-Object System.Drawing.Point(0, 0)
$titleLabel.Size = New-Object System.Drawing.Size(640, 34)
$headerPanel.Controls.Add($titleLabel)

$summaryPanel = New-Object System.Windows.Forms.Panel
$summaryPanel.Location = New-Object System.Drawing.Point(18, 74)
$summaryPanel.Size = New-Object System.Drawing.Size(888, 72)
$summaryPanel.Anchor = 'Top, Left, Right'
$summaryPanel.BackColor = $script:Colors.Surface
$summaryPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($summaryPanel)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '点击 [重新检测] 查看当前状态。'
$summaryLabel.Font = New-UiFont 10.5
$summaryLabel.ForeColor = $script:Colors.Text
$summaryLabel.Location = New-Object System.Drawing.Point(16, 12)
$summaryLabel.Size = New-Object System.Drawing.Size(845, 44)
$summaryLabel.Anchor = 'Top, Left, Right'
$summaryPanel.Controls.Add($summaryLabel)

$actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$actionPanel.Location = New-Object System.Drawing.Point(18, 160)
$actionPanel.Size = New-Object System.Drawing.Size(888, 42)
$actionPanel.Anchor = 'Top, Left, Right'
$actionPanel.BackColor = $script:Colors.Window
$actionPanel.WrapContents = $false
$form.Controls.Add($actionPanel)

$detectButton = New-Object System.Windows.Forms.Button
$detectButton.Text = '重新检测'
$detectButton.Size = New-Object System.Drawing.Size(116, 34)
Set-FlatButtonStyle $detectButton $false
$actionPanel.Controls.Add($detectButton)

$repairButton = New-Object System.Windows.Forms.Button
$repairButton.Text = '开始维修'
$repairButton.Size = New-Object System.Drawing.Size(116, 34)
Set-FlatButtonStyle $repairButton $true
$actionPanel.Controls.Add($repairButton)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = '已安装的应用'
$settingsButton.Size = New-Object System.Drawing.Size(132, 34)
Set-FlatButtonStyle $settingsButton $false
$actionPanel.Controls.Add($settingsButton)

$statusList = New-Object System.Windows.Forms.ListView
$statusList.View = [System.Windows.Forms.View]::Details
$statusList.FullRowSelect = $true
$statusList.GridLines = $false
$statusList.HideSelection = $false
$statusList.Font = New-UiFont 9.2
$statusList.BackColor = $script:Colors.Surface
$statusList.ForeColor = $script:Colors.Text
$statusList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$statusList.Location = New-Object System.Drawing.Point(18, 214)
$statusList.Size = New-Object System.Drawing.Size(888, 342)
$statusList.Anchor = 'Top, Bottom, Left, Right'
[void]$statusList.Columns.Add('状态', 86)
[void]$statusList.Columns.Add('检查项', 190)
[void]$statusList.Columns.Add('说明', 585)
$form.Controls.Add($statusList)

$detailBox = New-Object System.Windows.Forms.TextBox
$detailBox.Multiline = $true
$detailBox.ScrollBars = 'Vertical'
$detailBox.ReadOnly = $true
$detailBox.Font = New-UiFont 9
$detailBox.BackColor = $script:Colors.Surface
$detailBox.ForeColor = $script:Colors.Muted
$detailBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$detailBox.Location = New-Object System.Drawing.Point(18, 568)
$detailBox.Size = New-Object System.Drawing.Size(888, 40)
$detailBox.Anchor = 'Bottom, Left, Right'
$detailBox.Text = '选择上方检查项可查看完整路径或处理建议。'
$form.Controls.Add($detailBox)

function Update-StatusView {
  param([array]$Items)

  $statusList.Items.Clear()
  foreach ($item in $Items) {
    $row = New-Object System.Windows.Forms.ListViewItem($item.State)
    [void]$row.SubItems.Add($item.Name)
    [void]$row.SubItems.Add(($item.Detail -replace "\r?\n", '  '))
    $row.Tag = $item
    $palette = Get-StatePalette $item.State
    $row.BackColor = $palette.Back
    $row.ForeColor = $palette.Fore
    [void]$statusList.Items.Add($row)
  }

  $overall = Get-OverallState $Items
  $badCount = @($Items | Where-Object { $_.State -in @('缺失', '异常') }).Count
  $warnCount = @($Items | Where-Object { $_.State -in @('警告', '未知') }).Count
  if ($badCount -gt 0) {
    $summaryLabel.Text = "发现 $badCount 个需要维修的问题。请完全退出 Codex 和浏览器后点击 [开始维修]。"
  } elseif ($warnCount -gt 0) {
    $summaryLabel.Text = "关键插件包正常，但有 $warnCount 个提示项。请查看列表中的安装位置或未确认项。"
  } else {
    $summaryLabel.Text = '本地插件包、浏览器 native host 和关键缓存看起来正常。'
  }

  if ($Items.Count -gt 0) {
    $statusList.Items[0].Selected = $true
    $detailBox.Text = $Items[0].Detail
  }
}

$statusList.Add_SelectedIndexChanged({
  if ($statusList.SelectedItems.Count -gt 0) {
    $item = $statusList.SelectedItems[0].Tag
    $detailBox.Text = "[$($item.State)] $($item.Name)`r`n$($item.Detail)"
  }
})

$detectButton.Add_Click({
  try {
    $items = @(Get-PluginStatus)
    Update-StatusView $items
  } catch {
    $summaryLabel.Text = '检测失败。详情见下方。'
    $detailBox.Text = "检测失败：$($_.Exception.Message)"
  }
})

$repairButton.Add_Click({
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "维修前请确认：`r`n1. Codex 已完全退出。`r`n2. 浏览器已完全退出。`r`n3. 你接受将 openai-bundled 缓存移动到备份目录，让 Codex 下次启动重新生成。`r`n`r`n是否继续？",
    '确认维修',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    return
  }

  try {
    $resultText = Invoke-Repair
    $detailBox.Text = $resultText
    $items = @(Get-PluginStatus)
    Update-StatusView $items
    
    if ($resultText -notmatch "维修未执行") {
      [System.Windows.Forms.MessageBox]::Show(
        "修复执行完毕！`r`n`r`n请查看下方日志确认执行结果，然后可以重新启动 Codex 检查插件是否恢复正常。",
        '修复完成',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
      ) | Out-Null
    }
  } catch {
    $summaryLabel.Text = '维修失败。常见原因是 Codex、浏览器或 extension-host 仍在占用插件目录。'
    $detailBox.Text = "维修失败：$($_.Exception.Message)`r`n`r`n请退出 Codex、浏览器后重试。"
  }
})

$settingsButton.Add_Click({
  try {
    Open-InstalledAppsSettings
    [System.Windows.Forms.MessageBox]::Show(
      "已打开 Windows 设置 > 已安装的应用。`r`n如果检测到 Codex 不在 C 盘，可在这里尝试移动或修复安装。",
      '已打开设置',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show("打开设置失败：$($_.Exception.Message)") | Out-Null
  }
})

$form.Add_Shown({
  $detectButton.PerformClick()
})

[void]$form.ShowDialog()








