# Contributing to Mole

> **适用范围提示**：本文前半部分（Setup / Development / Code Style / Requirements / Go Components）继承自上游 [tw93/Mole](https://github.com/tw93/Mole) 的 macOS 版本。其中的 bash 工具链、`safe_*` 辅助函数和 BATS 测试**清道夫并未沿用** —— 清道夫是 Windows PowerShell 项目。
>
> 改动 `rules\rules.json` 请直接看本文末尾的 **[新增清理规则（Windows）](#新增清理规则windows)** 一节，以前面这些章节为准会走错方向。

## Setup

```bash
# Install development tools
brew install shfmt shellcheck bats-core golangci-lint

# Install goimports for better Go formatting
go install golang.org/x/tools/cmd/goimports@latest
```

## Development

Run quality checks before committing (auto-formats code):

```bash
./scripts/check.sh
```

Run tests:

```bash
./scripts/test.sh
```

## Code Style

### Basic Rules

- Bash 3.2+ compatible (macOS default)
- 4 spaces indent
- Use `set -euo pipefail` in all scripts
- Quote all variables: `"$variable"`
- Use `[[ ]]` not `[ ]` for tests
- Use `local` for function variables, `readonly` for constants
- Function names: `snake_case`
- BSD commands not GNU (e.g., `stat -f%z` not `stat --format`)

Config: `.editorconfig` and `.shellcheckrc`

### File Operations

**Always use safe wrappers, never `rm -rf` directly:**

```bash
# Single file/directory
safe_remove "/path/to/file"

# Purge files older than 7 days
safe_find_delete "$dir" "*.log" 7 "f"

# With sudo
safe_sudo_remove "/Library/Caches/com.example"
```

See `lib/core/file_ops.sh` for all safe functions.

### Pipefail Safety

All commands that might fail must be handled:

```bash
# Correct: handle failure
find /nonexistent -name "*.cache" 2>/dev/null || true

# Correct: check array before use
if [[ ${#array[@]} -gt 0 ]]; then
    for item in "${array[@]}"; do
        process "$item"
    done
fi

# Correct: arithmetic operations
((count++)) || true
```

### Error Handling

```bash
# Network requests with timeout
result=$(curl -fsSL --connect-timeout 2 --max-time 3 "$url" 2>/dev/null || echo "")

# Command existence check
if ! command -v brew >/dev/null 2>&1; then
    log_warning "Homebrew not installed"
    return 0
fi
```

### UI and Logging

```bash
# Logging
log_info "Starting cleanup"
log_success "Cache cleaned"
log_warning "Some files skipped"
log_error "Operation failed"

# Spinners
with_spinner "Cleaning cache" rm -rf "$cache_dir"

# Or inline
start_inline_spinner "Processing..."
# ... work ...
stop_inline_spinner "Complete"
```

### Debug Mode

Enable debug output with `--debug`:

```bash
mo --debug clean
./bin/clean.sh --debug
```

Modules check the internal `MO_DEBUG` variable:

```bash
if [[ "${MO_DEBUG:-0}" == "1" ]]; then
    echo "[MODULE] Debug message" >&2
fi
```

Format: `[MODULE_NAME] message` output to stderr.

## Requirements

- macOS 10.14 or newer, works on Intel and Apple Silicon
- Default macOS Bash 3.2+ plus administrator privileges for cleanup tasks
- Install Command Line Tools with `xcode-select --install` for curl, tar, and related utilities
- Go 1.24+ is required to build the `mo status` or `mo analyze` TUI binaries locally.

## Go Components

`mo status` and `mo analyze` use Go with Bubble Tea for interactive dashboards.

**Code organization:**

- Each module split into focused files by responsibility
- `cmd/analyze/` - Disk analyzer with 7 files under 500 lines each
- `cmd/status/` - System monitor with metrics split into 11 domain files

**Development workflow:**

- Format code with `gofmt -w ./cmd/...`
- Run `go vet ./cmd/...` to check for issues
- Build with `go build ./...` to verify all packages compile

**Building Go Binaries:**

For local development:

```bash
# Build binaries for current architecture
make build

# Or run directly without building
go run ./cmd/analyze
go run ./cmd/status
```

For releases, GitHub Actions builds architecture-specific binaries automatically.

**Guidelines:**

- Keep files focused on single responsibility
- Extract constants instead of magic numbers
- Use context for timeout control on external commands
- Add comments explaining **why** something is done, not just **what** is being done.

---

## 新增清理规则（Windows）

清道夫面向**不懂技术的普通用户**，核心卖点是「不会误删」。规则表 `rules\rules.json` 是数据驱动的，改它不需要动代码，但一条误删规则会毁掉整个工具的信誉，而漏掉一条只是少清几百 MB。

提交新规则的 PR 必须能通过下面的口径。拿不准的，按红线第 3 条降级处理，别硬判。

### 1. 四条红线

1. **只删能自动重建的东西** —— 缓存、日志、崩溃转储、临时文件。
2. **绝不碰用户数据** —— 文档、照片、视频、聊天记录、邮件、密码与登录凭据、许可证文件、软件配置、游戏存档、工作区文件、浏览器 Cookie 与登录态、应用插件/扩展。
3. **拿不准的，一律降级** —— `action: recycle` + `defaultSelected: false` + `minAgeDays` ≥ 30。
4. **宁可漏掉，不许误删。**

### 2. 证据要求：三样缺一不可

| # | 证据 | 来源 |
|---|---|---|
| 1 | 目标目录出现在探测报告里，且报告列出了**已知缓存子目录** | `scripts\Probe-AppOwnership.ps1` 的输出 |
| 2 | 目录内实际存在的缓存子目录名 | 同上，CacheLike 列 |
| 3 | 与现有规则 `pathTemplates` 的比对结论 | `rules\rules.json` |

比对必须看 **`pathTemplates`**，不是看 `name` 或 `id` —— 名字不同但路径重叠是最常见的重复来源。

**没有列出任何已知缓存子目录的目录，直接放弃。** 体积大不等于能删：一个 9 GB 的目录可能全是用户数据。

已知缓存子目录名单（以探测脚本 `Get-CacheLikeChildren` 为准，脚本更新则本节同步更新）：

```
Cache  Cache_Data  Code Cache  GPUCache  ShaderCache  GrShaderCache
DawnCache  DawnGraphiteCache  DawnWebGPUCache  Service Worker\CacheStorage
CachedData  CachedExtensions  blob_storage  Crashpad  crashpad  CrashDumps  Logs  logs
```

### 3. 字段决策树

```
删掉之后软件下次启动能自己重建吗？
├─ 能，且不可能含用户内容 → safe / delete / defaultSelected: true / minAgeDays: 0（或 7）
└─ 说不清，或目录里可能混了用户内容
   → careful / recycle / defaultSelected: false / minAgeDays: 30（或 90）
```

> **注意**：`Test-QdfRuleset`（`app\modules\Scanner.ps1`）只校验 `id` 唯一、`kind`/`action`/`risk` 的枚举合法性和 `category` 长度，**不校验 risk 与 action/defaultSelected 是否配套**。
> 也就是说，写一条 `safe` + `recycle` + `true` 的规则在校验层面是能通过的。配套关系靠本节自觉，PR review 时逐条看。
>
> 现存的唯一破例是 `shell-recent`（`safe` 但默认不勾选）——理由是最近使用记录会影响用户习惯，即便技术上可再生。破例请在 PR 里写明理由。

### 4. pathTemplates 三条硬约束

1. **必须指向缓存子目录本身，绝不指向应用根目录。**

```jsonc
// 正确
["%LOCALAPPDATA%\\Vendor\\App\\User Data\\*\\Cache",
 "%LOCALAPPDATA%\\Vendor\\App\\User Data\\*\\Code Cache"]

// 错误：会连带删掉配置、登录状态、用户内容
["%LOCALAPPDATA%\\Vendor\\App"]
```

2. **厂商/应用根段必须钉死，通配只允许出现在「实例层」**（profile 名、版本号、产品子名）。
3. 用反斜杠，支持 `%环境变量%`，也支持 `*` 通配目录层级。环境变量展开后交给 `Get-Item -Path` 解析，匹配不到会静默跳过 —— 没装该软件时规则自然失效。

### 5. 破例条款 A：通配厂商段（锚点原则）

现有 12 条含通配的规则全部是「厂商段钉死 + 通配实例层」：

```
%LOCALAPPDATA%\Adobe\*\Cache            %LOCALAPPDATA%\JetBrains\*\caches
%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache
```

把**厂商段也通配**是破例，需要同时满足三条：

1. 路径中存在**运行时专属目录名**作为锚点 —— 该目录名只可能由某个运行时创建，不会是软件的通用数据目录（如 `EBWebView`、`User Data`）；
2. 锚点之后仍落在**确定的缓存子目录名**上，通配**不落在末段**；
3. 人工确认过该锚点目录名下不存在用户数据层（Cookie / Local Storage / Login Data 等）。

**已批准先例**：`webview2-app-cache` —— 锚点 `EBWebView`，该目录只由 WebView2 运行时创建。

> **破例不设数量上限，一律逐条评审。** 先例只用来说明「这类形态曾被接受过」，不构成后续自动放行的依据 —— 每新增一条破例，仍要独立走完第 8 节的自检并在 PR 里写明理由。

```
%LOCALAPPDATA%\*\EBWebView\Default\Cache          ← 允许：锚点明确
%LOCALAPPDATA%\*\Cache                            ← 禁止：无锚点，会命中任何软件
```

### 6. 破例条款 B：非缓存目录立规则（脚本级证据通道）

目录名不在第 2 节的名单内 → **默认放弃**。要立规则，必须先补证据通道：

1. 在 `scripts\Probe-AppOwnership.ps1` 里加一个检测器，让报告输出明确标记（例如 `Test-QdfUpdaterCache` 输出 `updaterCache`）；
2. 人工**逐项核实**过目录内容（列出每一个文件，确认无用户数据）；
3. 起步设定**固定**为 `careful` + `recycle` + `defaultSelected: false` + `minAgeDays: 30`，运行满一个版本且零误删反馈后，才允许讨论升级为 `safe`。

**已批准先例**：`app-updater-installer-cache` —— `*-updater` 目录经逐项核实只含单个 `installer.exe`（electron-updater 残留安装包），探测脚本据此加了 `Test-QdfUpdaterCache`。

### 7. 通用放弃清单（无需讨论，直接放弃）

- WSL 虚拟磁盘（`Local\wsl`）、虚拟机镜像以外的发行版数据
- 需要开发者命令才能重建的二进制（`ms-playwright` 等）
- `Local\Package Cache` —— 删了破坏卸载/修复，业界共识禁删
- 应用插件/扩展目录（重建逻辑不受我们控制）
- 体积 < 15 MB 且归属不明的小目录 —— 收益撑不起规则噪声

### 8. 提交前自检（逐条回答，写进 PR 描述）

1. **证据**：探测报告里是否真的列出了这个目录，并列出了已知缓存子目录？没有 → 删掉这条规则。
2. **误删测试**：假设用户装的是正版软件、里面存了三年数据、且这个目录同时含有缓存和用户内容 —— 我的 `pathTemplates` 会不会碰到后者？
3. **重建性**：删掉之后，软件下次启动能自己重建吗？说不清 → 按第 3 节降级。
4. **重复**：现有规则的 `pathTemplates` 里有没有已经覆盖这个路径的？
5. **性能**：`recurse: true` 的目录会不会是几十万文件的巨型目录？会的话在 `description` 里写明扫描可能较慢（参考 `dev-uv`，单规则 21 万文件 / 4.2 GB）。

### 9. 验证命令（PR 必须附上输出）

改完 `rules\rules.json` 直接 dry-run（只读，不删任何东西），`-RuleIds` 只跑你新增的那几条。以下命令均在**仓库根目录**执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File app\modules\QdfCli.ps1 `
  -Command scan -RuleIds "<新规则id>"
```

不带 `-RulesPath` 时默认读 `rules\rules.json`。

输出是 NDJSON，检查两类东西：**命中文件的路径有没有越出缓存目录**、**`Skipped` 里有没有意外命中保护路径**。

然后跑测试套件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File qdf-tests\Run-Tests.ps1
```

> 输出编码坑：PowerShell 的外层重定向会把 UTF-8 的 NDJSON 转码损坏。落盘前先设 `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)`，再 `| Out-File -Encoding utf8`。

## Pull Requests

> **Important:** Please submit PRs to the `dev` branch, not `main`. We merge `dev` into `main` after testing.

1. Fork and create branch from `dev`
2. Make changes
3. Run checks: `./scripts/check.sh`
4. Commit and push
5. Open PR targeting `dev`

CI will verify formatting, linting, and tests.
