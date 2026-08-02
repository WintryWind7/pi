#Requires -Version 5.1
<#
.SYNOPSIS
	pi 仓库初始化脚本（供 AI 调用）：install + build + link + 同步配置，全流程固定。

.DESCRIPTION
	clone 后跑一次，全套就位。无交互、无选项，固定执行四步：
	  1. npm install        安装 workspace 依赖
	  2. npm run build      编译所有包，生成 dist/
	  3. npm link           注册全局 pi 命令 → packages/coding-agent/dist/cli.js
	  4. Junction 链接      ~/.pi/agent/{extensions,themes,prompts,skills} → 仓库 .pi/

	所有路径相对脚本自身定位，clone 到任何位置都能用：
	  - 仓库根  = 脚本所在目录
	  - 全局目录 = $HOME/.pi/agent（~/.pi/agent）

	步骤 4 用 Junction（目录连接）达成"仓库为单一配置源"：
	  - 仓库改一处，全局立刻生效（同一份实体）
	  - AI 改"全局扩展"实际改的是仓库那份（操作系统透明重定向）
	  - 物理上只有一份，不可能改错副本
	只链接 extensions/themes/prompts/skills 四个目录，绝不触碰本机状态：
	  auth.json(密钥) / sessions/ / bin/ / settings.json / models-* / trust.json / *.log
	这些独立留在 ~/.pi/agent/，不进 git。

	幂等：可重复运行。已链接的跳过，仓库更新后重跑即刷新（链接无需重建）。
#>

$ErrorActionPreference = "Stop"

# ============================================================================
# 路径定位（全部相对，不写死）
# ============================================================================

$RepoRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoPi         = Join-Path $RepoRoot ".pi"
$CodingAgentDir = Join-Path $RepoRoot "packages" "coding-agent"
$GlobalAgent    = Join-Path $HOME ".pi" "agent"
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
Write-Host "==[ 1/4 安装依赖 (npm install) ]==" -ForegroundColor Cyan
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
Write-Host "==[ 2/4 构建 (npm run build) ]==" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
	& npm run build
	if ($LASTEXITCODE -ne 0) { throw "npm run build 失败 (exit $LASTEXITCODE)" }
	$cliJs = Join-Path $CodingAgentDir "dist" "cli.js"
	if (-not (Test-Path $cliJs)) { throw "构建产物不存在：$cliJs" }
} finally { Pop-Location }
Write-Host "  [OK] 构建完成，dist/cli.js 已生成" -ForegroundColor Green

# ============================================================================
# 步骤 3：全局 link
# ============================================================================

Write-Host ""
Write-Host "==[ 3/4 全局 link (npm link) ]==" -ForegroundColor Cyan
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
# 步骤 4：链接配置（~/.pi/agent/{ext,themes,prompts,skills} → 仓库 .pi/）
# ============================================================================
# 用 Junction（目录连接）把全局目录链接到仓库，达成"仓库为单一配置源"：
#   - 仓库改了 → 全局立刻生效（同一份实体）
#   - AI 改"全局扩展"实际改的是仓库那份（操作系统透明重定向）
#   - 物理上只有一份，不可能改错副本
#
# 只链接四类资源目录。绝不链接、绝不触碰本机状态文件：
#   auth.json(密钥) / sessions/ / bin/ / settings.json / models-* / trust.json / *.log
# 这些独立留在 ~/.pi/agent/，不进 git。

Write-Host ""
Write-Host "==[ 4/4 链接配置 ]==" -ForegroundColor Cyan

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

# ============================================================================
# 完成
# ============================================================================

Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "  pi 初始化完成" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host "任意目录运行 pi 即可使用本仓库的扩展与主题。" -ForegroundColor White
