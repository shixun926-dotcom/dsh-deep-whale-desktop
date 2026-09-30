# 将 dsh-deep-whale 皮肤部署到 DSH 桌面端（Electron）profile
#
# 背景（本脚本依据的实测结论，详见 DESKTOP.md）：
#   1. 桌面端以 `profile: "desktop"` 运行同一套 @deepseek-ai/dsh-web-app（默认端口 19387），
#      与网页端是同一个 DSH 运行时；客户端插件平台标识只有 "web" 一个取值，
#      因此皮肤的 dsh.client.platform: "web" 声明对桌面端本来就正确，无需改代码。
#   2. 普通 `dsh plugin --profile desktop ...` 会被 @deepseek-ai/dsh/lib/bin.js 拒绝：
#      “profile "desktop" is managed exclusively by the Electron application”。
#      桌面端自带 CLI（resources\runtime\cli\bin\dsh.cmd）会以 manageDesktopProfile: true
#      调用 runCli，因此**插件安装/卸载必须走这个 CLI**。
#   3. 启动与 --dump-config 仍由应用独占（CLI 无法 boot desktop profile），
#      所以新增插件包后需要用户重启桌面应用。
#
# 用法：
#   pwsh -File .\install-desktop-skins.ps1                        # 默认激活 maid-atelier
#   pwsh -File .\install-desktop-skins.ps1 -Target orca-link      # 激活虎鲸链路
#   pwsh -File .\install-desktop-skins.ps1 -Target official       # 全部皮肤停用
#   pwsh -File .\install-desktop-skins.ps1 -AppRoot "D:\DSH"      # 手动指定桌面端安装目录

[CmdletBinding()]
param(
  # DSH 桌面端安装目录（含 "DeepSeek Harness.exe"）；留空则自动探测
  [string]$AppRoot,
  # 本仓库根目录；默认取脚本所在目录
  [string]$RepoRoot = $PSScriptRoot,
  [ValidateSet('maid-atelier', 'orca-link', 'official')]
  [string]$Target = 'maid-atelier',
  [string]$Profile = 'desktop'
)

$ErrorActionPreference = 'Stop'

function Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Fail($text) { Write-Host "失败：$text" -ForegroundColor Red; exit 1 }

# 1. 定位桌面端安装目录与其自带 CLI（唯一被允许管理 desktop profile 的入口）
Step '定位桌面端安装目录'
if (-not $AppRoot) {
  $candidates = @(
    $env:DSH_DESKTOP_APP,
    'D:\ProjectTool\DSH',
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
    (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')
  ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'DeepSeek Harness.exe')) }
  $AppRoot = $candidates | Select-Object -First 1
}
if (-not $AppRoot) {
  Fail '未找到 DSH 桌面端安装目录，请用 -AppRoot 指定（该目录应包含 "DeepSeek Harness.exe"）'
}
$cli = Join-Path $AppRoot 'resources\runtime\cli\bin\dsh.cmd'
$exe = Join-Path $AppRoot 'DeepSeek Harness.exe'
if (-not (Test-Path $exe)) { Fail "找不到桌面应用：$exe" }
if (-not (Test-Path $cli)) { Fail "找不到桌面端 CLI：$cli" }
Write-Host "应用     : $exe"
Write-Host "CLI      : $cli"
Write-Host "仓库     : $RepoRoot"

# 2. 扫描仓库内皮肤（实时读取 skin.json，不硬编码清单）
Step '扫描皮肤清单'
$skins = Get-ChildItem $RepoRoot -Directory |
  Where-Object { Test-Path (Join-Path $_.FullName 'skin.json') } |
  ForEach-Object {
    $manifest = Get-Content (Join-Path $_.FullName 'skin.json') -Raw | ConvertFrom-Json
    [pscustomobject]@{
      Id       = $manifest.id
      Name     = $manifest.name
      Package  = $manifest.package
      WiringId = $manifest.wiring.id
      Dir      = $_.FullName
    }
  } | Sort-Object Id
if (-not $skins) { Fail "仓库内没有找到任何 skin.json：$RepoRoot" }
$skins | Format-Table Id, Name, Package, WiringId -AutoSize

# 3. 预置互斥状态（必须在任何 plugin add 之前；只写托管块，保留其余 YAML）
Step "预置互斥状态（激活目标：$Target）"
$stage = Join-Path $RepoRoot '.agents\skills\dsh-skin-install\scripts\stage-mutual-exclusion.mjs'
if (-not (Test-Path $stage)) { Fail "找不到互斥脚本：$stage" }
& node $stage --profile $Profile --target $Target
if ($LASTEXITCODE -ne 0) { Fail '互斥状态预置失败，已中止（不要继续安装）' }

# 4. 注册 skin-manager 与全部皮肤（绝对路径 -> pnpm link:）
Step '注册皮肤包到桌面 profile'
$manager = Join-Path $RepoRoot 'skin-manager'
if (Test-Path $manager) {
  & $cli plugin --profile $Profile add $manager
  if ($LASTEXITCODE -ne 0) { Fail 'skin-manager 注册失败' }
}
foreach ($skin in $skins) {
  & $cli plugin --profile $Profile add $skin.Dir
  if ($LASTEXITCODE -ne 0) { Fail "$($skin.Id) 注册失败" }
}

# 5. 验证：依赖清单 + bundle 列表
Step '验证注册结果'
& $cli plugin --profile $Profile list

$manifestPath = Join-Path $env:USERPROFILE ".dsh\profiles\$Profile\package.json"
$profileManifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$missing = @()
foreach ($name in @($skins.Package) + '@dsh-external/dsh-client-ui-skin-deep-whale-manager') {
  if ($profileManifest.dsh.profile.bundles -notcontains $name) { $missing += $name }
}
if ($missing) { Fail "以下包不在 dsh.profile.bundles 中：$($missing -join ', ')" }
Write-Host 'dsh.profile.bundles 已包含全部皮肤包' -ForegroundColor Green

$profilePatch = Join-Path $env:USERPROFILE ".dsh\profiles\$Profile\cordis.patch.yml"
Write-Host "`nprofile patch 末尾：" -ForegroundColor DarkGray
Get-Content $profilePatch | Select-Object -Last 8

Write-Host "`n完成。新增插件包需要重启桌面应用才会加载：" -ForegroundColor Yellow
Write-Host '  完全退出 DeepSeek Harness（托盘右键 → 退出应用，确保进程结束）后重新打开，刷新即可看到皮肤。' -ForegroundColor Yellow
