#Requires -Version 5.1
<#
.SYNOPSIS
	pi 仓库初始化脚本（供 AI 调用）：install + build + link + 同步配置，全流程固定。

.DESCRIPTION
	clone 后跑一次，全套就位。无交互、无选项，固定执行五步：
	  1. npm install        安装 workspace 依赖
	  2. npm run build      编译所有包，生成 dist/（优先离线，data 缺失才联网）
	  3. npm link           注册全局 pi 命令 → packages/coding-agent/dist/cli.js
	  4. 配置同步           链接资源目录，并同步第三方插件配置
	  5. pi install         登记正式扩展，并安装固定版本的全局第三方包

	所有路径相对脚本自身定位，clone 到任何位置都能用：
	  - 仓库根  = 脚本所在目录
	  - 全局目录 = $HOME/.pi/agent（~/.pi/agent）

	步骤 4 用 Junction（目录连接）达成"仓库为单一配置源"：
	  - 仓库改一处，全局立刻生效（同一份实体）
	  - AI 改"全局扩展"实际改的是仓库那份（操作系统透明重定向）
	  - 物理上只有一份，不可能改错副本
	第三方插件的非敏感配置由仓库 .pi/web-search.json 管理，并在步骤 4
	同步到 ~/.pi/web-search.json。

	资源启用机制差异（已核实源码）：
	  - skills/prompts/themes：pi 自动扫描 ~/.pi/agent/{skills,prompts,themes}/ 目录
	    → 步骤 4 链接后即生效，无需登记
	  - extensions：pi 只读 settings.json 的 packages 数组，不扫描目录
	    → 步骤 4 链接只让文件就位，必须步骤 5 的 pi install 登记才被加载
	  - 第三方 npm 包：步骤 5 固定版本安装到 ~/.pi/agent/npm/，并登记进
	    settings.json；另一台机器 clone 后运行本脚本即可恢复

	步骤 5 只通过 `pi install` 登记仓库扩展路径和固定版本 npm 包，
	不触碰其他敏感本机状态：
	  auth.json(密钥) / sessions/ / bin/ / models-* / trust.json / *.log
	这些独立留在 ~/.pi/agent/，不进 git。

	幂等：可重复运行。已链接的跳过，pi install 对已登记扩展不会重复追加。
#>

$ErrorActionPreference = "Stop"

# ============================================================================
# 路径定位（全部相对，不写死）
# ============================================================================

$RepoRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoPi         = Join-Path $RepoRoot ".pi"
$CodingAgentDir = Join-Path $RepoRoot "packages" "coding-agent"
$GlobalPi       = Join-Path $HOME ".pi"
$GlobalAgent    = Join-Path $GlobalPi "agent"
$Resources      = @("extensions", "themes", "prompts", "skills")

# ============================================================================
# 前置检查
# ============================================================================

Write-Host "pi 初始化（全流程）" -ForegroundColor Cyan
Write-Host "  仓库根  : $RepoRoot" -ForegroundColor DarkGray
Write-Host "  全局目录: $GlobalAgent" -ForegroundColor DarkGray

if (-not (Test-Path $RepoPi)) {
	Write-Error "仓库 .pi/ 不存在：$RepoPi（确认脚本位于 pi 仓库根目录）"
	exit 1
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Error "未找到 node"; exit 1 }
if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { Write-Error "未找到 npm";  exit 1 }

# ============================================================================
# 步骤 1：安装依赖
# ============================================================================

Write-Host ""
Write-Host "==[ 1/5 安装依赖 (npm install) ]==" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
	& npm install --no-fund --no-audit
	if ($LASTEXITCODE -ne 0) { throw "npm install 失败 (exit $LASTEXITCODE)" }
} finally { Pop-Location }
Write-Host "  [OK] 依赖安装完成" -ForegroundColor Green

# ============================================================================
# 步骤 2：构建
# ============================================================================

Write-Host ""
Write-Host "==[ 2/5 构建 ]==" -ForegroundColor Cyan

# 构建策略：优先离线构建（不联网、不重新生成 data），失败时按原因分流：
#   - data 缺失/过期（check:model-data 报 "missing or stale" / "does not exist"）
#     → 回退到联网构建（npm run build，会跑 generate-models 拉 models.dev 生成 data）
#   - 其他失败（真编译错误）→ 直接报错，不回退，避免无谓联网浪费时间
# 联网回退仍失败（如访问不了 models.dev）→ 明确报错退出，提示从其他机器拷贝 data，
# 不静默跳过，避免制造"看起来成功但 pi 不可用"的假象。
Push-Location $RepoRoot
try {
	$cliJs = Join-Path $CodingAgentDir "dist" "cli.js"

	# 2a. 先尝试离线构建（用现有 data，不联网）
	Write-Host "  尝试离线构建 (npm run build:offline)..." -ForegroundColor DarkGray
	$offlineOutput = & npm run build:offline 2>&1 | Out-String
	$offlineExit = $LASTEXITCODE

	if ($offlineExit -eq 0) {
		Write-Host "  [OK] 离线构建成功（data 已就位，跳过联网）" -ForegroundColor Green
	} else {
		# 判断是否 data 问题（check:model-data 的专属错误信号）
		$isDataIssue = $offlineOutput -match "missing or stale|does not exist|Model data is"
		if (-not $isDataIssue) {
			# 真编译错误，直接报错，不回退
			Write-Host $offlineOutput -ForegroundColor Red
			throw "离线构建失败（非 data 问题，疑似编译错误，exit $offlineExit）"
		}

		# 2b. data 问题 → 回退联网构建（generate-models 会拉 models.dev）
		Write-Host "  data 缺失或过期，回退联网构建 (npm run build)..." -ForegroundColor Yellow
		Write-Host "  （此步会访问 models.dev 生成模型数据，需要网络）" -ForegroundColor DarkGray
		$onlineOutput = & npm run build 2>&1 | Out-String
		$onlineExit = $LASTEXITCODE
		if ($onlineExit -ne 0) {
			Write-Host $onlineOutput -ForegroundColor Red
			throw @"
联网构建失败 (exit $onlineExit)。

data 缺失且联网生成失败（常见原因：无法访问 models.dev）。
请从其他已就绪的机器拷贝 data 目录到本机：
  源：packages/ai/src/providers/data/   （含 37 个 json + .manifest.json）
  目标：$RepoPi\..\packages\ai\src\providers\data\
拷贝完成后重跑本脚本，离线构建即可通过。
"@
		}
		Write-Host "  [OK] 联网构建成功（已生成 data）" -ForegroundColor Green
	}

	if (-not (Test-Path $cliJs)) { throw "构建产物不存在：$cliJs" }
} finally { Pop-Location }
Write-Host "  [OK] 构建完成，dist/cli.js 已生成" -ForegroundColor Green

# ============================================================================
# 步骤 3：全局 link
# ============================================================================

Write-Host ""
Write-Host "==[ 3/5 全局 link (npm link) ]==" -ForegroundColor Cyan
Push-Location $CodingAgentDir
try {
	& npm link
	if ($LASTEXITCODE -ne 0) { throw "npm link 失败 (exit $LASTEXITCODE)" }
} finally { Pop-Location }
$piCmd = Get-Command pi -ErrorAction SilentlyContinue
if ($piCmd) {
	Write-Host "  [OK] pi 命令：$($piCmd.Source)" -ForegroundColor Green
} else {
	Write-Host "  [警告] pi 未在 PATH（重启终端或检查 npm 全局 bin 目录）" -ForegroundColor Yellow
}

# ============================================================================
# 步骤 4：链接资源并同步第三方插件配置
# ============================================================================
# 用 Junction（目录连接）把全局目录链接到仓库，达成"仓库为单一配置源"：
#   - 仓库改了 → 全局立刻生效（同一份实体）
#   - AI 改"全局扩展"实际改的是仓库那份（操作系统透明重定向）
#   - 物理上只有一份，不可能改错副本
#
# 只链接四类资源目录。不链接本机状态文件：
#   auth.json(密钥) / sessions/ / bin/ / models-* / trust.json / *.log
# 这些独立留在 ~/.pi/agent/，不进 git。
# 注：settings.json 不在此处链接，但步骤 5 会通过 pi install 往其 packages 数组登记扩展。

Write-Host ""
Write-Host "==[ 4/5 链接配置 ]==" -ForegroundColor Cyan

if (-not (Test-Path $GlobalAgent)) {
	New-Item -ItemType Directory -Path $GlobalAgent -Force | Out-Null
}

# 判断路径是否已是指向目标的 Junction（幂等：已链接则跳过）
function Test-JunctionTarget {
	param([string]$LinkPath, [string]$ExpectedTarget)
	if (-not (Test-Path $LinkPath)) { return $false }
	$item = Get-Item $LinkPath -Force -ErrorAction SilentlyContinue
	if (-not $item) { return $false }
	$isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
	if (-not $isReparse) { return $false }
	# 解析 Junction 目标
	$resolved = $item.Target
	if (-not $resolved) {
		# 某些 PS 版本 Target 为空，用 .NET 解析
		$dirInfo = [System.IO.DirectoryInfo]::new($LinkPath)
		$resolved = $dirInfo.ResolveLinkTarget($true)?.FullName
	}
	return ($resolved -and ($resolved.TrimEnd('\','/') -eq $ExpectedTarget.TrimEnd('\','/')))
}

foreach ($res in $Resources) {
	$srcDir = Join-Path $RepoPi $res        # 仓库实体目录
	$dstDir = Join-Path $GlobalAgent $res   # 全局链接位置

	if (-not (Test-Path $srcDir)) {
		Write-Host "  [SKIP] $res （仓库无此目录）" -ForegroundColor DarkGray
		continue
	}

	# 已是正确链接 → 跳过
	if (Test-JunctionTarget -LinkPath $dstDir -ExpectedTarget $srcDir) {
		Write-Host "  [OK]   $res 已链接 → $srcDir" -ForegroundColor Green
		continue
	}

	# 目标位置已存在（非链接，或链接指向别处）→ 需要处理
	if (Test-Path $dstDir) {
		# 安全检查：若已是链接但指向别处，先删链接；若是真实目录且有内容，警告并跳过，避免误删用户数据
		$item = Get-Item $dstDir -Force -ErrorAction SilentlyContinue
		$isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
		if ($isReparse) {
			# 是链接但指向不对，删除重建
			Remove-Item $dstDir -Force -Recurse
		} else {
			# 真实目录：检查是否为空
			$hasContent = (Get-ChildItem $dstDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
			if ($hasContent) {
				Write-Host "  [WARN] $res 全局已存在非空真实目录，跳过以免误删：" -ForegroundColor Yellow
				Write-Host "         $dstDir" -ForegroundColor Yellow
				Write-Host "         如需改用链接，请先手动处理该目录。" -ForegroundColor Yellow
				continue
			}
			Remove-Item $dstDir -Force -Recurse
		}
	}

	# 创建 Junction：全局目录 → 仓库目录
	New-Item -ItemType Junction -Path $dstDir -Target $srcDir -ErrorAction Stop | Out-Null
	Write-Host "  [OK]   $res 链接 → $srcDir" -ForegroundColor Green
}

$repoWebSearchConfig = Join-Path $RepoPi "web-search.json"
$globalWebSearchConfig = Join-Path $GlobalPi "web-search.json"
if (Test-Path $repoWebSearchConfig) {
	Copy-Item -Path $repoWebSearchConfig -Destination $globalWebSearchConfig -Force
	Write-Host "  [OK]   web-search.json 已同步 → $globalWebSearchConfig" -ForegroundColor Green
} else {
	Write-Host "  [SKIP] web-search.json（仓库无此配置）" -ForegroundColor DarkGray
}

# ============================================================================
# 步骤 5：登记扩展与安装第三方包（pi install）
# ============================================================================
# extensions 与 skills/prompts/themes 不同：pi 只读 settings.json 的 packages
# 数组，不扫描目录。步骤 4 的链接只让文件就位，必须在此登记才被 pi 加载。
# 只登记正式扩展（目录型）；散落在 extensions/ 根的单文件（import-repro/tps/
# redraws/prompt-url-widget）是开发调试工具，不登记。
# 固定版本 npm 包同样在此安装并登记；安装命令强制官方 registry、TLS 校验和
# ignore-scripts。pi install 对已登记扩展和已安装固定版本包保持幂等。

Write-Host ""
Write-Host "==[ 5/5 登记扩展与安装第三方包 (pi install) ]==" -ForegroundColor Cyan

$FormalExtensions = @("WintryWind7-prompt", "WintryWind7-ui")
foreach ($extName in $FormalExtensions) {
	$extPath = Join-Path $RepoPi "extensions" $extName
	if (-not (Test-Path $extPath)) {
		Write-Host "  [SKIP] $extName （仓库无此扩展目录：$extPath）" -ForegroundColor DarkGray
		continue
	}
	# pi install 会把扩展路径登记进全局 settings.json 的 packages 数组
	& pi install $extPath 2>&1 | Out-Host
	if ($LASTEXITCODE -ne 0) {
		throw "pi install $extName 失败 (exit $LASTEXITCODE)"
	}
	Write-Host "  [OK]   $extName 已登记" -ForegroundColor Green
}

$GlobalPackages = @("npm:pi-web-access@0.19.0")
$previousTlsSetting = [Environment]::GetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED", "Process")
$previousRegistrySetting = [Environment]::GetEnvironmentVariable("npm_config_registry", "Process")
$previousIgnoreScriptsSetting = [Environment]::GetEnvironmentVariable("npm_config_ignore_scripts", "Process")
try {
	[Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED", "1", "Process")
	[Environment]::SetEnvironmentVariable("npm_config_registry", "https://registry.npmjs.org", "Process")
	[Environment]::SetEnvironmentVariable("npm_config_ignore_scripts", "true", "Process")

	foreach ($package in $GlobalPackages) {
		& pi install $package 2>&1 | Out-Host
		if ($LASTEXITCODE -ne 0) {
			throw "pi install $package 失败 (exit $LASTEXITCODE)"
		}
		Write-Host "  [OK]   $package 已安装" -ForegroundColor Green
	}
} finally {
	[Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED", $previousTlsSetting, "Process")
	[Environment]::SetEnvironmentVariable("npm_config_registry", $previousRegistrySetting, "Process")
	[Environment]::SetEnvironmentVariable("npm_config_ignore_scripts", $previousIgnoreScriptsSetting, "Process")
}

# ============================================================================
# 完成
# ============================================================================

Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "  pi 初始化完成" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host "任意目录运行 pi 即可使用本仓库的扩展、主题与联网工具。" -ForegroundColor White
