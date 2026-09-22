# 清道夫

Windows 普通用户的便携式空间清理工具。基于 [tw93/Mole](https://github.com/tw93/Mole) Windows 分支继续开发，正式交付的是清道夫 GUI，而不是旧 Mole 命令行安装包。

## 当前版本：v1.1.1

**以实际发布的 v1.1.0 为基线修整，完整保留其 82 条规则，包括新增的 11 条。**
其中 6 条旧规则出于安全原因暂时禁用，仍保留定义与原因；实际启用的是 75 条清理规则及 1 条只读大文件规则。规则数量不等于扫描命中数量，未安装对应软件时会自动隐藏空类别。

本版本重点修复路径边界、清理中断记录、回执编码、任务并发与大结果传输。更新记录见 [RELEASE.md](RELEASE.md)。

## 下载与使用

从 [Releases](https://github.com/rcrusoe88-bot/qingdaofu/releases/latest) 下载 `qingdaofu-1.1.1-x64.zip` 和 `SHA256SUMS.txt`。

1. 核对来源与 SHA-256：`Get-FileHash .\qingdaofu-1.1.1-x64.zip -Algorithm SHA256`。
2. 解压整个文件夹，保留 EXE 同目录下的 `app\`、`rules\`；不要只复制 EXE。
3. 双击“启动清道夫.cmd”。在“清理”页扫描，展开候选路径并勾选，再确认处理。
4. “分析”页只读展示大文件；“记录”页查看操作状态和回执。

> 未签名程序可能触发 Windows 或杀毒软件警告，但不能一概认定是误报。无法确认来源、校验值或报警原因时停止运行；不要为整个目录关闭防护、加入白名单或直接恢复被隔离文件。哈希用于完整性核验，不等同于数字签名或安全认证。

系统要求：Windows 10 22H2 / Windows 11 x64、普通用户权限、WebView2 运行时。核心扫描与清理不主动上传文件路径、文件名或软件清单。

## 保留的 v1.1.0 新增规则

| 规则 | 处理方式 |
| --- | --- |
| uv、Claude 桌面版、Antigravity 缓存 | 默认勾选，永久删除 |
| ima.copilot、WPS Office、火绒应用商店缓存 | 默认勾选，永久删除 |
| 浏览器 Crashpad、WebView2、Cherry Studio 缓存 | 默认勾选，永久删除 |
| 更新器残留安装包、Claude 虚拟机镜像 | 默认不勾选，30 天阈值，移入回收站 |

这 11 条规则的定义与 v1.1.0 发行基线保持一致；这不代表本轮对所有第三方应用进行了真实删除验证。

## 安全边界与行为变化

- 扫描不删除文件。永久删除不可恢复；回收站文件仍占空间，需用户自行清空才释放。
- 检查候选路径和所有祖先的重解析点；永久删除时固定父目录，并通过文件句柄重新校验大小与修改时间。不可验证、被占用或已变化的项目不会强行删除。
- 清理前建立回执，每个文件持久化计划与结果。中断后只有计划、没有结果的项目标为“未知”，不会假定成功。
- 清理可请求停止，等待当前操作及回执保存；运行期间关闭窗口先请求停止，完成后可再次关闭。扫描或 Windows 回收站对话框可能需要等待。
- 后台失败会恢复界面；同一窗口不允许并行启动清理/扫描任务。
- AWS、Azure、Kubernetes、Steam 规则与保护目录冲突，暂时禁用；Office 与 Zoom 的宽泛数据目录规则暂停，等待专项验证。GOG 的 ProgramData 日志目标已移除。**没有通过取消保护来启用规则。**
- 旧 Go 分析器删除入口已关闭。旧 Mole CLI 不在正式清道夫便携包中，其余旧代码不等同于本次已验证的产品范围。

**限制**：回收站仍依赖 Windows 路径接口；即使固定父目录，也不宣称对恶意同用户进程的所有竞态提供完整隔离。断电、系统强制结束后的未知结果需要用户核查。此版本未完成所有第三方应用、所有 Windows 环境的人工验收。

## 操作数据

`%LOCALAPPDATA%\QingDaoFu\receipts` 保存 JSON 回执及同名 `.jsonl` 逐项记录；`logs` 保存摘要日志。
界面展示部分明细，完整逐项日志留在本地。日志包含文件路径，应按个人数据保管。

## 开发、测试与打包

需要 Go（版本要求见 `go.mod`）、Node.js、Windows PowerShell 5.1、Pester 3.4.0 和 Wails CLI v2.16.0。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qdf-tests\Run-Tests.ps1
go test -mod=readonly ./gui ./cmd/...
go vet -mod=readonly ./gui ./cmd/...
node --test qdf-tests/frontend.test.cjs

# 重新构建 GUI、运行测试、校验 ZIP；输出至新的 release/build-* 目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-portable.ps1

# 对下载或生成的实际 ZIP 独立校验
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Test-PortableArchive.ps1 -ArchivePath <zip路径>
```

打包校验覆盖完整 82 条规则 ID、11 条新增规则定义、VERSION、EXE 版本以及包内文件哈希。包内 `BUILD-MANIFEST.json` 记录源提交、规则集合、构建时间、验证方式与文件哈希。

发布流程使用同一个打包入口，自动生成草稿；核验 CI、实际附件和 SHA-256 后才公开发布。不再复用未经重建的 EXE，也不使用旧 `scripts/build-release.ps1` 发布清道夫。

本轮验证不包括真实用户缓存的破坏性清理、真实回收站端到端验收或 Go race 检测；后者需要额外的 CGO/C 编译器。

## 许可证

MIT。来源说明见 `THIRD_PARTY_NOTICES.md`，上游原始说明保留在 `README-MOLE.md`。
