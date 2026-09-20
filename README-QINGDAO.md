# 清道夫

清道夫是一个面向 Windows 普通用户的便携式空间清理工具。它基于
[tw93/Mole](https://github.com/tw93/Mole) 的 `windows` 分支继续开发，
第一版只处理当前用户权限下的已知缓存和候选文件。

## 使用方式

1. 解压整个便携包。
2. 双击 `启动清道夫.cmd`。
3. 点击“开始扫描”。
4. 检查类别、风险和路径后，选择需要处理的内容。
5. 确认后执行清理，并查看操作回执。

扫描本身不会删除文件。明确可再生的缓存会在最终确认后永久删除；
下载文件和安装包等可能包含个人内容的项目会移入回收站。

## 安全边界

- 不请求管理员权限。
- 不清理注册表、WinSxS、Windows Update、休眠文件和系统还原点。
- 不强制关闭浏览器或其他应用，被占用文件会跳过。
- 不扫描重解析点，不跟随目录联接或符号链接。
- 所有候选文件必须位于规则展开出的目录内，并通过保护路径校验。
- 永久删除与移入回收站会在确认窗口中分别列出。
- 回收站中的文件仍然占用磁盘空间，需要用户自行清空回收站后才会释放。

## 扫描范围

默认勾选：

- 7 天未修改的用户临时文件。
- Chrome、Edge 和 Firefox 的网页缓存。
- Windows 缩略图与图标缓存。
- 已审计的 Discord 和 Slack 缓存。

默认不勾选：

- 90 天未修改的下载文件，处理时进入回收站。
- 桌面上的旧安装包，处理时进入回收站。

只读展示：

- 用户常用目录中大于 1GB 的文件，不提供删除操作。

## 数据位置

程序运行数据保存在：

```text
%LOCALAPPDATA%\QingDaoFu
```

其中 `receipts` 保存每次操作的候选文件回执，`logs` 保存摘要日志。
清道夫不会联网，也不会上传文件路径、文件名或软件清单。

## 系统要求

- Windows 10 22H2 或 Windows 11 x64。
- Windows PowerShell 5.1。
- 普通用户权限。

## 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qdf-tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Portable.ps1
```

## 许可证

项目继续使用 MIT 许可证。来源说明见 `THIRD_PARTY_NOTICES.md`。
