// Backend bridge. This is the ONLY file that touches the Wails bindings,
// so a rename on the Go side breaks here and nowhere else.
//
// When the bindings are missing (page opened in a plain browser) a mock is
// installed instead, so the UI can be iterated on without rebuilding the Go
// binary or waiting out a real multi-minute scan. The mock mirrors the
// QdfCli.ps1 NDJSON contract exactly — see the plan for the field list.
(function () {
  'use strict';

  const bindings = (window.go && window.go.main && window.go.main.App) || null;
  const EventsOn = (window.runtime && window.runtime.EventsOn) || null;

  if (bindings && EventsOn) {
    window.QDF = {
      live: true,
      scan: (ids) => bindings.Scan(ids || []),
      clean: (ids) => bindings.Clean(ids || []),
      cancel: () => bindings.Cancel(),
      strings: () => bindings.GetStrings(),
      rules: () => bindings.GetRules(),
      history: (n) => bindings.GetHistory(n || 50),
      receipt: (path) => bindings.GetReceipt(path),
      openPath: (target) => bindings.OpenPath(target),
      on: (event, handler) => EventsOn(event, handler),
    };
    return;
  }

  // ---- dev mock (never reached inside the Wails shell) ----
  console.warn('[清道夫] Wails bindings 缺失，已启用 mock 数据（仅供界面调试）');

  const f = (Path, Size) => ({ Path, Name: Path.split('\\').pop(), Size, LastWriteTimeUtc: '2026-08-01T04:12:00.0000000Z' });
  const KB = 1024;
  const MB = 1024 * 1024;

  const MOCK_SCAN = {
    type: 'result',
    RulesPath: 'rules\\rules.json',
    StartedAt: '',
    CompletedAt: new Date().toISOString(),
    Categories: [
      { Id: 'dev-vscode', Category: '开发缓存', Name: 'VS Code 缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'VS Code 的缓存与扩展安装包缓存，不动工作区记录和设置。',
        ItemCount: 383, TotalSize: 903.9 * MB, TotalSizeText: '903.9 MB', DetailsTruncated: false,
        Files: [f('C:\\Users\\wsj19\\AppData\\Roaming\\Code\\CachedExtensionVSIXs\\ms-vscode.cpptools.vsix', 187.4 * MB)] },
      { Id: 'chrome-cache', Category: '浏览器', Name: 'Chrome 网页缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: '清理 Chrome 配置目录中的网页、代码和 GPU 缓存，不处理历史记录、Cookie 和密码。',
        ItemCount: 6172, TotalSize: 796.7 * MB, TotalSizeText: '796.7 MB', DetailsTruncated: true,
        Files: [f('C:\\Users\\wsj19\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache\\Cache_Data\\f_0001a2', 8.4 * MB)] },
      { Id: 'dev-npm', Category: '开发缓存', Name: 'npm 缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'npm 下载过的包缓存，删掉后重新安装会重新下载。',
        ItemCount: 21003, TotalSize: 512.4 * MB, TotalSizeText: '512.4 MB', DetailsTruncated: true, Files: [] },
      { Id: 'dev-go-mod', Category: '开发缓存', Name: 'Go 模块缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Go 下载的模块缓存，重新构建会重新下载。',
        ItemCount: 1158, TotalSize: 141.8 * MB, TotalSizeText: '141.8 MB', DetailsTruncated: false, Files: [] },
      { Id: 'dev-pip', Category: '开发缓存', Name: 'pip 缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Python 包下载缓存。',
        ItemCount: 168, TotalSize: 132.1 * MB, TotalSizeText: '132.1 MB', DetailsTruncated: false, Files: [] },
      { Id: 'sync-onedrive', Category: '云同步', Name: 'OneDrive 日志', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'OneDrive 的同步日志，不动任何同步的文件。',
        ItemCount: 652, TotalSize: 73.1 * MB, TotalSizeText: '73.1 MB', DetailsTruncated: false, Files: [] },
      { Id: 'user-temp', Category: '系统与用户项', Name: '用户临时文件', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: '清理 7 天未修改的当前用户临时文件，正在使用的文件会自动跳过。',
        ItemCount: 4437, TotalSize: 61.5 * MB, TotalSizeText: '61.5 MB', DetailsTruncated: true, Files: [] },
      { Id: 'app-office', Category: '办公与创意', Name: 'Office 缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Word / Excel / PowerPoint 的文档缓存与 Outlook 的离线地址簿缓存。',
        ItemCount: 467, TotalSize: 37.0 * MB, TotalSizeText: '37.0 MB', DetailsTruncated: false, Files: [] },
      { Id: 'browser-chrome-shader', Category: '浏览器', Name: 'Chrome 着色器缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Chrome 的 ShaderCache 与 GrShaderCache。',
        ItemCount: 115, TotalSize: 12.3 * MB, TotalSizeText: '12.3 MB', DetailsTruncated: false, Files: [] },
      { Id: 'browser-edge-shader', Category: '浏览器', Name: 'Edge 着色器缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Edge 的 ShaderCache 与 GrShaderCache。',
        ItemCount: 67, TotalSize: 10.4 * MB, TotalSizeText: '10.4 MB', DetailsTruncated: false, Files: [] },
      { Id: 'windows-thumbnail-cache', Category: '系统与用户项', Name: '缩略图和图标缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: '清理 Windows Explorer 生成的缩略图和图标缓存，系统会按需自动重建。',
        ItemCount: 30, TotalSize: 10.0 * MB, TotalSizeText: '10.0 MB', DetailsTruncated: false, Files: [] },
      { Id: 'edge-cache', Category: '浏览器', Name: 'Edge 网页缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: '清理 Edge 配置目录中的网页、代码和 GPU 缓存，不处理历史记录、Cookie 和密码。',
        ItemCount: 54, TotalSize: 7.7 * MB, TotalSizeText: '7.7 MB', DetailsTruncated: false, Files: [] },
      { Id: 'gpu-directx', Category: '显卡缓存', Name: 'DirectX 着色器缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Windows 自带的 DirectX 着色器缓存，系统会自动重建。',
        ItemCount: 116, TotalSize: 3.2 * MB, TotalSizeText: '3.2 MB', DetailsTruncated: false, Files: [] },
      { Id: 'dev-bun', Category: '开发缓存', Name: 'Bun 安装缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Bun 下载的包缓存。',
        ItemCount: 16, TotalSize: 1.0 * MB, TotalSizeText: '1.0 MB', DetailsTruncated: false, Files: [] },
      { Id: 'app-store', Category: '聊天与影音', Name: '应用商店缓存', Risk: 'safe', Action: 'delete', DefaultSelected: true,
        Description: 'Microsoft Store 的本地缓存。',
        ItemCount: 1, TotalSize: 5002, TotalSizeText: '4.9 KB', DetailsTruncated: false, Files: [] },
      { Id: 'shell-recent', Category: '系统与用户项', Name: '最近使用的文件记录', Risk: 'safe', Action: 'delete', DefaultSelected: false,
        Description: '资源管理器「最近使用的文件」列表与跳转列表，30 天前的记录。只删快捷方式记录，不动原文件。',
        ItemCount: 11, TotalSize: 2.9 * KB, TotalSizeText: '2.9 KB', DetailsTruncated: false, Files: [] },

      { Id: 'im-wechat-plugin', Category: '国内软件', Name: '微信小程序 / 视频号插件', Risk: 'careful', Action: 'recycle', DefaultSelected: false,
        Description: '小程序与视频号的运行插件。删掉后微信会按需重新下载，首次打开小程序可能卡一下。',
        ItemCount: 284, TotalSize: 700.2 * MB, TotalSizeText: '700.2 MB', DetailsTruncated: false, Files: [] },
      { Id: 'im-wechat-log', Category: '国内软件', Name: '微信日志', Risk: 'careful', Action: 'recycle', DefaultSelected: false,
        Description: '微信的运行日志。不碰聊天记录、图片和接收到的文件。',
        ItemCount: 48, TotalSize: 109.5 * MB, TotalSizeText: '109.5 MB', DetailsTruncated: false, Files: [] },
      { Id: 'app-office-tmp', Category: '办公与创意', Name: 'Office 自动恢复临时文件', Risk: 'careful', Action: 'recycle', DefaultSelected: false,
        Description: 'Office 自动恢复留下的 .tmp 文件。只处理 7 天前的。',
        ItemCount: 4, TotalSize: 85.7 * MB, TotalSizeText: '85.7 MB', DetailsTruncated: false, Files: [] },
      { Id: 'im-wechat-cache', Category: '国内软件', Name: '微信内置浏览器缓存', Risk: 'careful', Action: 'recycle', DefaultSelected: false,
        Description: '微信内置 Chromium 的缓存与崩溃报告。刻意不动同级的 radium\\users。',
        ItemCount: 9, TotalSize: 1.8 * MB, TotalSizeText: '1.8 MB', DetailsTruncated: false, Files: [] },
      { Id: 'downloads-old-90', Category: '下载与安装包', Name: '90 天未访问的下载文件', Risk: 'careful', Action: 'recycle', DefaultSelected: false,
        Description: '将下载目录中 90 天未修改的文件移入回收站，不永久删除。',
        ItemCount: 0, TotalSize: 0, TotalSizeText: '0 B', DetailsTruncated: false, Files: [] },
    ],
    LargeFiles: [
      f('D:\\Virtual\\win11-dev.vhdx', 24.6 * 1024 * MB),
      f('D:\\Games\\cyberpunk-2077.iso', 12.1 * 1024 * MB),
      f('C:\\Users\\wsj19\\Videos\\屏幕录制 2026-09-20.mp4', 4.8 * 1024 * MB),
      f('C:\\Users\\wsj19\\Documents\\backup-2026q2.zip', 2.4 * 1024 * MB),
    ],
    Skipped: [],
    TotalCandidateSize: 330.2 * MB,
    TotalCandidateSizeText: '330.2 MB',
  };

  const MOCK_CLEAN = {
    type: 'result', StartedAt: '', CompletedAt: new Date().toISOString(), DryRun: false,
    SelectedRuleIds: ['user-temp', 'chrome-cache', 'edge-cache', 'windows-thumbnail-cache'],
    ScannedCandidateCount: 2812, ProcessedCount: 2806, SuccessfulCount: 2806,
    FailedCount: 6, SkippedCount: 0,
    BytesFreed: 480 * MB, BytesFreedText: '480.0 MB',
    BytesRecycled: 0, BytesRecycledText: '0 B',
    Failures: [
      { RuleId: 'user-temp', Path: 'C:\\Users\\wsj19\\AppData\\Local\\Temp\\~DF3A2B.tmp', Action: 'delete', Success: false, Reason: '文件正被另一个进程使用' },
      { RuleId: 'chrome-cache', Path: 'C:\\Users\\wsj19\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache\\Cache_Data\\f_0001a2', Action: 'delete', Success: false, Reason: '拒绝访问' },
    ],
    ReceiptPath: 'C:\\Users\\wsj19\\AppData\\Local\\QingDaoFu\\receipts\\20260920-211500.json',
  };

  const MOCK_HISTORY = [
    { StartedAt: '2026-09-20T21:15:00+08:00', CompletedAt: new Date(Date.now() - 3600e3).toISOString(), DryRun: false,
      SelectedRuleIds: ['user-temp', 'chrome-cache', 'edge-cache'], SuccessfulCount: 2806, FailedCount: 6,
      BytesFreed: 480 * MB, BytesFreedText: '480.0 MB', BytesRecycled: 0, BytesRecycledText: '0 B',
      ReceiptPath: 'C:\\Users\\wsj19\\AppData\\Local\\QingDaoFu\\receipts\\20260920-211500.json' },
    { StartedAt: '2026-09-14T10:02:00+08:00', CompletedAt: new Date(Date.now() - 6 * 86400e3).toISOString(), DryRun: false,
      SelectedRuleIds: ['user-temp', 'downloads-old-90'], SuccessfulCount: 344, FailedCount: 0,
      BytesFreed: 96 * MB, BytesFreedText: '96.0 MB', BytesRecycled: 2.8 * 1024 * MB, BytesRecycledText: '2.80 GB',
      ReceiptPath: 'C:\\Users\\wsj19\\AppData\\Local\\QingDaoFu\\receipts\\20260914-100200.json' },
  ];

  const listeners = {};
  const emit = (ev, payload) => setTimeout(() => (listeners[ev] || []).forEach((h) => h(payload)), 40);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  window.QDF = {
    live: false,
    // Walks the real rule list so the checklist animation can be previewed,
    // then hands over the mock scan result.
    scan: async () => {
      const names = MOCK_SCAN.Categories.map((c) => c.Name).concat(['大于 1GB 的只读文件']);
      for (let i = 0; i < names.length; i++) {
        emit('scan:progress', { type: 'progress', phase: 'scan', index: i + 1, total: names.length, ruleName: names[i] });
        await sleep(160);
      }
      emit('scan:done', MOCK_SCAN);
      return null;
    },
    clean: async () => { await sleep(900); emit('clean:done', MOCK_CLEAN); return null; },
    cancel: async () => null,
    // Reuses the real strings file so the mock never drifts from production
    // copy. Requires the preview to be served from the repo root.
    strings: () => fetch('../../app/strings.zh-CN.json').then((r) => r.text()),
    rules: () => fetch('../../rules/rules.json').then((r) => r.text()),
    history: async () => MOCK_HISTORY,
    receipt: async () => ({ Summary: MOCK_CLEAN, Items: [], ReceiptTruncated: false }),
    openPath: async () => null,
    on: (event, handler) => { (listeners[event] = listeners[event] || []).push(handler); },
    // Dev handle for jumping straight to a given state from the console:
    //   scanResult = QDF._mock.scan; scanState = 'review'; renderClean()
    _mock: { scan: MOCK_SCAN, clean: MOCK_CLEAN, history: MOCK_HISTORY },
  };
})();
