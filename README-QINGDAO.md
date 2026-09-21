# 清道夫

清道夫是一个面向 Windows 普通用户的便携式空间清理工具。它基于
[tw93/Mole](https://github.com/tw93/Mole) 的 `windows` 分支继续开发，
只处理当前用户权限下的已知缓存和候选文件。

## 使用方式

1. 解压整个便携包（不要只把 exe 拷出来，它需要同目录的 `app\` 和 `rules\`）。
2. 双击 `启动清道夫.cmd`。
3. 在「清理」页点「开始扫描」。
4. 展开类别、检查路径后，勾选需要处理的内容。
5. 确认后执行清理，并查看操作回执。

界面分三个页签：

- **清理** —— 扫描 → 勾选 → 清理 → 回执。
- **分析** —— 列出用户目录中大于 1GB 的文件，只读展示，不提供删除。
- **记录** —— 历次操作的历史与回执详情。

扫描本身不会删除文件。明确可再生的缓存会在最终确认后永久删除；
可能包含个人内容的项目会移入回收站。

## 扫描范围

按「可再生缓存 / 需要你确认」分成两组。默认勾选的都是**删掉之后会自动重建**
的缓存，不增加误删风险。

**可再生缓存（默认勾选，永久删除）**

| 类别 | 覆盖内容 |
| --- | --- |
| 显卡缓存 | NVIDIA / AMD / Intel 的着色器缓存，DirectX 与 Vulkan 缓存 |
| 浏览器 | Chrome、Edge、Firefox、Brave、Opera 的网页与着色器缓存 |
| 开发缓存 | npm / Yarn / Bun / pip / Poetry / NuGet / Go / Cargo / Gradle 等包缓存，VS Code、JetBrains、Visual Studio、Zed、Sublime 的索引与缓存 |
| 聊天与影音 | Discord、Slack、Teams、Zoom、Spotify、应用商店缓存 |
| 办公与创意 | Office 文档缓存、Adobe 媒体缓存、Autodesk 缓存 |
| 云同步 | OneDrive 与 Google Drive 的同步日志 |
| 游戏启动器 | Steam、Epic、EA、GOG、育碧、战网的启动器缓存 |
| 系统与用户项 | 用户临时文件、缩略图与图标缓存、错误报告与崩溃转储 |

**需要你确认（默认不勾选，移入回收站）**

| 类别 | 覆盖内容 |
| --- | --- |
| 下载与安装包 | 90 天未修改的下载文件、桌面上的旧安装包 |
| 录屏与截图 | 90 天前的游戏录屏、截图与游戏回放 |
| 国内软件 | 微信的日志、内置浏览器缓存、小程序与视频号插件 |
| 办公与创意 | Office 自动恢复留下的临时文件（只处理 7 天前的） |

**只读展示**：用户常用目录中大于 1GB 的文件，不提供删除操作。

> 规则表是数据驱动的（`rules\rules.json`）。某台机器上没装对应软件时，
> 那一类会扫到 0 个文件并自动隐藏，不会出现在界面上。

## 安全边界

- 不请求管理员权限。
- 不清理注册表、WinSxS、Windows Update、休眠文件和系统还原点。
- 不强制关闭浏览器或其他应用，被占用文件会跳过。
- 不扫描重解析点，不跟随目录联接或符号链接。
- 所有候选文件必须位于规则展开出的目录内，并通过保护路径校验。
- 保护名单覆盖系统目录、密钥与凭据目录（`.ssh`、`.aws`、`.kube` 等），
  以及浏览器 Cookie、登录数据、聊天数据库这类文件。
- 永久删除与移入回收站会在确认窗口中分别列出。
- 回收站中的文件仍然占用磁盘空间，需要用户自行清空回收站后才会释放。
- 清理前会重新扫描一次候选文件，只删除这次扫描确认过的文件。

## 数据位置

程序运行数据保存在：

```text
%LOCALAPPDATA%\QingDaoFu
```

其中 `receipts` 保存每次操作的候选文件回执，`logs` 保存摘要日志。
清道夫不会联网，也不会上传文件路径、文件名或软件清单。

## 系统要求

- Windows 10 22H2 或 Windows 11 x64。
- 普通用户权限。
- WebView2 运行时（Windows 11 与较新的 Windows 10 已内置）。

## 开发与验证

```powershell
# 单元测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qdf-tests\Run-Tests.ps1

# 打包便携版（会先构建 GUI，产物在 dist\）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Portable.ps1

# 只读探测：在当前机器上验证清理目标路径与体积，不删除任何文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Probe-Targets.ps1
```

## 许可证

项目继续使用 MIT 许可证。来源说明见 `THIRD_PARTY_NOTICES.md`。
