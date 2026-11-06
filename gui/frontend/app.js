/* 清道夫 — 三 Tab 外壳（清理 / 分析 / 记录）
 *
 * 后端访问一律走 QDF（见 api.js）；所有文案来自 strings.zh-CN.json。
 * 本文件不直接触碰 window.go / window.runtime。
 *
 * 清理页有五个子态：idle → scanning → review → cleaning → done。
 * scanResult 是 app 级共享状态，分析页直接复用，不重复扫描。
 */

let T = {};                   // 界面文案
let tab = 'clean';            // 当前 tab
let scanState = 'idle';       // 清理页子态
let scanResult = null;        // 最近一次扫描结果（清理页 / 分析页共用）
let scanSeen = [];            // 扫描中已出现的规则名，用于逐条打勾
let selected = new Set();     // 已勾选的规则 id
let cleanResult = null;
let cleanProgress = null;     // 清理中最近一次进度事件（规则序号 + 已处理条目）
let doneExitTimers = [];      // 完成页退场动画的计时器，重渲染前统一撤掉
let historyRows = null;
let orphanState = 'idle';     // 已卸载残留子态：idle / scanning / done
let orphanResult = null;
let receiptOpen = null;       // 当前展开的回执路径
let ruleNames = {};           // 规则 id → 中文名（历史与回执里只有 id）

// 状态页：每 3 秒读一次只读快照，离开页签就停
let statusData = null;
let statusTimer = null;
let statusBusy = false;
let statusHist = { cpu: [], mem: [], net: [] };

// 分析页：磁盘树图 + 最大文件 + 卸载残留
let analyzeNode = null;
let analyzeDrives = null;
let analyzeLoading = false;
let analyzeError = '';
let analyzeTab = 'tree';        // tree | largest | orphans | drives
let analyzeMulti = false;
let analyzeSelected = new Set();
let analyzeReq = 0;
let analyzeCtxNode = null;

function operationState(state) {
    return ({ Completed: '已完成', Partial: '部分失败', Cancelled: '已停止（部分完成）', Incomplete: '未完成，部分结果可能未知', Failed: '执行失败' })[state] || state || '已完成';
}

function onTaskError(e) {
    showError(e && e.message ? e.message : String(e));
    if (scanState === 'scanning' || scanState === 'cleaning') {
        // Never reuse a snapshot after a potentially partial cleanup.
        scanState = 'idle'; scanResult = null; selected = new Set(); historyRows = null; cleanProgress = null;
        renderClean();
    }
}

const $ = (id) => document.getElementById(id);
const arr = (x) => (Array.isArray(x) ? x : []);

/* 路径来自文件系统，任何插进 DOM 的字符串都必须先过 esc() */
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ESC[c]);

/* 与 Core.ps1 的 Format-QdfSize 保持一致：1024 进制，N2 / N1 / N1 */
function fmtSize(bytes) {
    const n = Math.round(Number(bytes) || 0);
    const GB = 1073741824, MB = 1048576, KB = 1024;
    const group = (s) => {
        const [i, f] = s.split('.');
        return i.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (f ? '.' + f : '');
    };
    if (n >= GB) return group((n / GB).toFixed(2)) + ' GB';
    if (n >= MB) return group((n / MB).toFixed(1)) + ' MB';
    if (n >= KB) return group((n / KB).toFixed(1)) + ' KB';
    return n + ' B';
}

function fmtCount(n) {
    return Number(n || 0).toLocaleString('zh-CN');
}

function fmtWhen(iso) {
    if (!iso) return '';
    // PowerShell round-trip ("o") timestamps carry 7 fractional digits, which
    // Date.parse does not reliably accept — trim to milliseconds first.
    const d = new Date(String(iso).replace(/(\.\d{3})\d+/, '$1'));
    if (isNaN(d.getTime())) return String(iso);
    const p = (x) => String(x).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function badge(cls, text) {
    return text ? `<span class="badge ${cls}">${esc(text)}</span>` : '';
}

/* 操作历史和回执只记规则 id；没有映射时退回显示 id，不吞掉信息 */
function ruleLabel(id) {
    return ruleNames[id] || id;
}

function riskBadge(risk) {
    const key = { safe: 'riskSafe', careful: 'riskCareful', readonly: 'riskReadonly' }[risk];
    return badge(risk, key ? T[key] : risk);
}

function actionBadge(action) {
    const key = { delete: 'actionDelete', recycle: 'actionRecycle' }[action];
    return key ? badge(action, T[key]) : '';
}

/* 空类别不展示——"已检查、什么都没有"不值得占一行 */
function liveCategories() {
    return arr(scanResult && scanResult.Categories).filter((c) => c.ItemCount > 0 || c.TotalSize > 0);
}

function selectedLive() {
    return liveCategories().filter((c) => selected.has(c.Id));
}

function selectedBytes() {
    return selectedLive().reduce((sum, c) => sum + (Number(c.TotalSize) || 0), 0);
}

function showError(message) {
    $('errorMessage').textContent = message;
    $('errorBanner').classList.remove('hidden');
}

/* ---------------- Tab 路由 ---------------- */

const RENDER = { clean: renderClean, analyze: renderAnalyze, history: renderHistory, status: renderStatus };

function showTab(next) {
    tab = next;
    // 每个页签一套世界底色（CSS 用 body[data-tab] 切渐变与 hero 器物）
    if (document.body) document.body.dataset.tab = next;
    if (next === 'status') startStatusPolling(); else stopStatusPolling();
    document.querySelectorAll('.tab').forEach((b) => {
        b.setAttribute('aria-selected', String(b.dataset.tab === next));
    });
    document.querySelectorAll('.tabpane').forEach((p) => {
        p.classList.toggle('hidden', p.dataset.pane !== next);
    });
    RENDER[next]();
}

/* ---------------- 清理页 ---------------- */

function renderClean() {
    const scroll = $('cleanScroll');
    if (scanState === 'idle') scroll.innerHTML = heroIdle();
    else if (scanState === 'scanning') scroll.innerHTML = viewScanning();
    else if (scanState === 'review') scroll.innerHTML = viewReview();
    else if (scanState === 'cleaning') scroll.innerHTML = viewCleaning();
    else if (scanState === 'done') scroll.innerHTML = viewDone();
    renderCleanFooter();
}

function heroIdle() {
    return `<div class="hero">
        <div class="hero-value hero-sm">${esc(T.scanHeading || '')}</div>
        <div class="hero-sub">${esc(T.scanDescription || '')}</div>
    </div>`;
}

function viewScanning() {
    const last = scanSeen[scanSeen.length - 1] || {};
    const total = last.total || 0;
    const n = scanSeen.length;
    const pct = total ? Math.round(((n - 1) / total) * 100) : 0;

    const items = scanSeen.map((s, i) => {
        const active = i === n - 1;
        return `<div class="check-item ${active ? 'active' : 'done'}"><span class="mark">${active ? '' : '✓'}</span><span>${esc(s.name)}</span></div>`;
    }).join('');
    const left = total > n
        ? `<div class="check-item pending"><span class="mark"></span><span>${esc(T.scanning || '')}</span></div>`
        : '';
    const bar = total
        ? `<div class="bar"><i style="width:${Math.max(2, pct)}%"></i></div>`
        : `<div class="bar indet"><i></i></div>`;

    return `<div class="hero">
        <div class="hero-label">${esc(T.statusScanning || '')}</div>
        <div class="hero-value">${n}${total ? ` / ${total}` : ''}</div>
        <div class="hero-sub">${esc(last.name || '')}</div>
    </div>
    <div class="card"><div class="pad">${bar}<div class="checklist scan-sweep" id="scanSweep">${items}${left}</div></div></div>`;
}

function viewCleaning() {
    const p = cleanProgress || {};
    const total = Number(p.total) || 0;
    const index = Number(p.index) || 0;
    const items = Number(p.items) || 0;
    const bytes = Number(p.bytes) || 0;
    const pct = total ? Math.round(((index - 1) / total) * 100) : 0;
    const sub = [
        p.ruleName || '',
        items ? `${T.cleanProcessed || ''} ${items} ${T.itemSuffix || ''}` : '',
        bytes ? `${T.summaryFreed || ''} ${fmtSize(bytes)}` : '',
    ].filter(Boolean).join(' · ');
    const bar = total
        ? `<div class="bar"><i style="width:${Math.max(2, Math.min(100, pct))}%"></i></div>`
        : `<div class="bar indet"><i></i></div>`;
    return `<div class="hero">
        <div class="hero-label">${esc(T.statusCleaning || '')}</div>
        ${total ? `<div class="hero-value">${index} / ${total}</div>` : ''}
        <div class="hero-sub">${esc(sub || T.cleaningNow || '')}</div>
    </div>
    <div class="card"><div class="pad">${bar}</div></div>`;
}

function viewReview() {
    const cats = liveCategories();
    const del = cats.filter((c) => c.Action === 'delete');
    const rec = cats.filter((c) => c.Action === 'recycle');

    // The shim's TotalCandidateSize sums every non-readonly rule, which
    // includes the recycle rules — and those bytes are NOT freed. So the hero
    // is derived from the delete group, with the recycle side called out
    // separately rather than folded into one misleading number.
    const safeBytes = del.reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);
    const recBytes = rec.reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);
    const nCats = new Set(cats.map((c) => c.Category || '')).size;
    const sub = [
        `${nCats} ${T.categorySuffix || ''}`,
        `${cats.length} ${T.itemSuffix || ''}`,
        `${T.scannedAt || ''} ${fmtWhen(scanResult.CompletedAt)}`,
    ];
    if (recBytes) sub.push(`${T.heroPending || ''} ${fmtSize(recBytes)} ${T.heroPendingSuffix || ''}`);

    const head = `<div class="hero">
        <div class="hero-label">${esc(T.heroCleanable || '')}</div>
        <div class="hero-value">${esc(fmtSize(safeBytes))}</div>
        <div class="hero-sub">${sub.map(esc).join(' · ')}</div>
    </div>`;

    const groups = [
        { rules: del, title: T.groupRenewable, key: 'delete' },
        { rules: rec, title: T.groupConfirm, key: 'recycle' },
    ].filter((g) => g.rules.length).map(sectionCard).join('');

    const lf = arr(scanResult.LargeFiles);
    const lfCard = lf.length ? `<div class="card">
        <div class="group-head">
            <span class="group-title">${esc(T.largeFilesHeading || '')}</span>
            <span class="group-meta">${lf.length} ${esc(T.itemSuffix || '')} · ${esc(fmtSize(lf.reduce((s, f) => s + (Number(f.Size) || 0), 0)))}</span>
            <span class="group-tools"><button class="btn small ghost" data-action="go-analyze">${esc(T.tabAnalyze || '')}</button></span>
        </div>
        <div style="padding:12px 18px" class="footer-note">${esc(T.largeFilesDescription || '')}</div>
    </div>` : '';

    if (!cats.length && !lf.length) {
        return head + `<div class="card empty"><div class="empty-title">${esc(T.noItems || '')}</div></div>`;
    }
    return head + groups + lfCard;
}

/* 一个安全分区（可再生缓存 / 需要你确认）。分区是首要信号——「会不会真删掉」
   比「属于哪一类」重要——所以它在顶层，类别作为可折叠的子组放在里面。 */
function sectionCard(section) {
    const rules = section.rules;
    const allOn = rules.every((r) => r.DefaultSelected);
    const allOff = rules.every((r) => !r.DefaultSelected);
    const bytes = rules.reduce((s, r) => s + (Number(r.TotalSize) || 0), 0);

    // risk/action are uniform inside a section today, so the header can carry
    // them once. If a future rule breaks that, stamp them on the rows instead.
    const uniformRisk = rules.every((r) => r.Risk === rules[0].Risk) ? rules[0].Risk : null;
    const uniformAction = rules.every((r) => r.Action === rules[0].Action) ? rules[0].Action : null;
    const perRowBadges = !(uniformRisk && uniformAction);

    const byCat = new Map();
    for (const r of rules) {
        const key = r.Category || T.otherCategory || '';
        if (!byCat.has(key)) byCat.set(key, []);
        byCat.get(key).push(r);
    }
    const catBytes = (rs) => rs.reduce((s, r) => s + (Number(r.TotalSize) || 0), 0);
    const cats = [...byCat.entries()]
        .map(([name, rs]) => ({ name, rules: rs.sort((a, b) => (Number(b.TotalSize) || 0) - (Number(a.TotalSize) || 0)) }))
        .sort((a, b) => catBytes(b.rules) - catBytes(a.rules));

    const meta = [
        `${cats.length} ${T.categorySuffix || ''}`,
        `${rules.length} ${T.itemSuffix || ''}`,
        fmtSize(bytes),
    ].join(' · ') + (allOn ? ` · ${T.defaultOn || ''}` : allOff ? ` · ${T.defaultOff || ''}` : '');

    return `<div class="card section">
        <div class="section-head">
            <span class="group-title">${esc(section.title)}</span>
            ${riskBadge(uniformRisk)}${actionBadge(uniformAction)}
            <span class="group-meta">${esc(meta)}</span>
            <span class="group-tools">
                <button class="btn small ghost" data-action="group-all" data-group="${esc(section.key)}">${esc(T.selectAll || '')}</button>
                <button class="btn small ghost" data-action="group-none" data-group="${esc(section.key)}">${esc(T.selectNone || '')}</button>
            </span>
        </div>
        ${cats.map((c) => catBlock(c, perRowBadges)).join('')}
    </div>`;
}

function catBlock(group, perRowBadges) {
    const bytes = group.rules.reduce((s, r) => s + (Number(r.TotalSize) || 0), 0);
    return `<div class="cat-block">
        <button class="cat-head" data-action="toggle-cat" type="button">
            <span class="cat-caret">▾</span>
            <span class="cat-name">${esc(group.name)}</span>
            <span class="cat-meta">${group.rules.length} ${esc(T.itemSuffix || '')} · ${esc(fmtSize(bytes))}</span>
        </button>
        <div class="cat-body">${group.rules.map((c) => ruleRow(c, perRowBadges)).join('')}</div>
    </div>`;
}

function ruleRow(c, showBadges) {
    const on = selected.has(c.Id);
    const size = Number(c.TotalSize) || 0;
    const files = arr(c.Files);
    const detail = files.length
        ? `<button class="rule-detail" data-action="toggle-detail">${esc(T.detailsHeading || '')} ${c.ItemCount} ▾</button>`
        : '';
    return `<div class="rule ${on ? '' : 'off'}" data-rule-id="${esc(c.Id)}">
        <div class="rule-top" data-action="toggle-rule">
            <input type="checkbox" data-rule-id="${esc(c.Id)}" ${on ? 'checked' : ''}>
            <div class="rule-main">
                <div class="rule-line">
                    <span class="rule-name">${esc(c.Name)}</span>
                    ${showBadges ? riskBadge(c.Risk) + actionBadge(c.Action) : ''}
                </div>
                <div class="rule-desc">${esc(c.Description)}</div>
            </div>
            <div class="rule-side">
                <div class="rule-size ${size ? '' : 'zero'}">${esc(c.TotalSizeText || fmtSize(size))}</div>
                ${detail}
            </div>
        </div>
    </div>`;
}

function viewDone() {
    const r = cleanResult || {};
    const freed = Number(r.BytesFreed) || 0;
    const recycled = Number(r.BytesRecycled) || 0;
    const rows = [
        [T.summaryProcessed, String(r.SuccessfulCount || 0), false],
        [T.summaryRecycled, r.BytesRecycledText || '0 B', false],
        [T.summarySkipped, String(r.SkippedCount || 0), false],
        [T.summaryFailed, String(r.FailedCount || 0), Number(r.FailedCount) > 0],
    ];
    return `<div class="hero">
        <div class="hero-label">${esc(T.heroReleased || '')}</div>
        <div class="hero-value">${esc(r.BytesFreedText || fmtSize(freed))}</div>
        <div class="hero-sub">${esc(T.doneHeading || '')}${recycled ? ` · ${esc(T.summaryRecycled)} ${esc(r.BytesRecycledText)}` : ''}</div>
    </div>
    <div class="card">
        <div class="group-head"><span class="group-title">${esc(T.doneSummary || '')}</span></div>
        <div style="padding:14px 18px">
            <div class="kv">${rows.map(([k, v, danger]) =>
                `<div><dt>${esc(k)}</dt><dd class="${danger ? 'danger' : ''}">${esc(v)}</dd></div>`).join('')}</div>
            <div class="footer-note">${esc(T.receiptPath || '')}：${esc(r.ReceiptPath || '')}</div>
        </div>
    </div>${doneRuleList(r)}`;
}

/* 本次处理了哪些规则——逐条列出，而不是只给四个统计数字。
   缩小淡出退场（縮小フェード退場）在这里退场：每条已处理的规则收敛成一点消失，
   底部「已释放」同步累加。 */
function doneRuleList(r) {
    const items = arr(r.RuleResults);
    if (!items.length) return '';
    const rows = items.map((it) => {
        const n = Number(it.Successful) || 0;
        const failed = Number(it.Failed) || 0;
        const skipped = Number(it.Skipped) || 0;
        const freed = Number(it.BytesFreed) || 0;
        const recycled = Number(it.BytesRecycled) || 0;
        const bytes = freed > 0 ? fmtSize(freed) : (recycled > 0 ? fmtSize(recycled) : '');
        // 没命中任何文件（软件没装）要说出来，不能看起来像"查过但没发现"
        const state = !it.Handled
            ? `<span class="done-state none">未发现目标</span>`
            : failed > 0
                ? `<span class="done-state fail">失败 ${failed}</span>`
                : recycled > 0 && freed <= 0
                    ? `<span class="done-state ok">已移入回收站</span>`
                    : skipped > 0
                        ? `<span class="done-state skip">跳过 ${skipped}</span>`
                        : `<span class="done-state ok">已处理 ${n}</span>`;
        return `<div class="done-row" data-rule-id="${esc(it.RuleId)}">
            <span class="done-mark">✓</span>
            <span class="done-name">${esc(it.RuleName || it.RuleId)}</span>
            ${state}
            <span class="done-size">${esc(bytes)}</span>
        </div>`;
    }).join('');
    return `<div class="card">
        <div class="group-head">
            <span class="group-title">${esc(T.doneRulesHeading || '本次处理')}</span>
            <span class="group-meta">${items.length} ${esc(T.itemSuffix || '')}</span>
        </div>
        <div class="done-list" id="doneList">${rows}</div>
        <div class="done-tally">${esc(T.summaryFreed || '已释放')} <b id="doneTally">0 B</b></div>
    </div>`;
}

function renderCleanFooter() {
    const f = $('cleanFooter');
    if (scanState === 'idle') {
        f.innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.scanDescription || '')}</span></div>
            <button class="btn primary" data-action="scan">${esc(T.scanButton || '')}</button>`;
    } else if (scanState === 'scanning') {
        f.innerHTML = `<div class="footer-summary"><span class="footer-lead">${esc(T.statusScanning || '')}</span></div>
            <button class="btn" data-action="cancel">${esc(T.cancelScan || '')}</button>`;
    } else if (scanState === 'review') {
        const n = selectedLive().length;
        const summary = n
            ? `<span class="footer-lead">${esc(T.selectedPrefix || '')} ${n} ${esc(T.itemSuffix || '')} · ${esc(fmtSize(selectedBytes()))}</span>`
            : `<span class="footer-note">${esc(T.nothingSelected || '')}</span>`;
        f.innerHTML = `<div class="footer-summary">${summary}</div>
            <button class="btn ghost" data-action="rescan">${esc(T.refreshButton || '')}</button>
            <button class="btn primary" data-action="clean" ${n ? '' : 'disabled'}>${esc(T.cleanCta || '')} ${n} ${esc(T.itemSuffix || '')}</button>`;
    } else if (scanState === 'cleaning') {
        f.innerHTML = `<div class="footer-summary"><span class="footer-lead">${esc(T.statusCleaning || '')}</span></div><button class="btn ghost" data-action="cancel">停止并保存回执</button>`;
    } else {
        const r = cleanResult || {};
        const failed = Number(r.FailedCount) || 0;
        f.innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.summaryProcessed || '')} ${Number(r.SuccessfulCount) || 0} ${esc(T.itemSuffix || '')}${failed ? ` · ${esc(T.summaryFailed || '')} ${failed}` : ''}</span></div>
            <button class="btn ghost" data-action="open-recyclebin">${esc(T.openRecycleBin || '')}</button>
            <button class="btn ghost" data-action="empty-recyclebin">${esc(T.emptyRecycleBin || '')}</button>
            <button class="btn primary" data-action="scan">${esc(T.scanButton || '')}</button>`;
    }
}

/* ---------------- 分析页 ---------------- */

const TM_COLORS = [
    'rgba(126, 163, 148, .42)',
    'rgba(176, 138, 106, .42)',
    'rgba(150, 126, 150, .42)',
    'rgba(120, 140, 170, .42)',
    'rgba(160, 150, 110, .40)',
];

function analyzeCrumbs(path) {
    const all = { label: T.allDisks || '所有磁盘', path: '' };
    if (!path) return [all];
    const parts = String(path).split(/[\\/]/).filter(Boolean);
    const out = [all];
    let acc = '';
    for (const p of parts) {
        acc = acc ? acc + '\\' + p : p;
        if (acc.length === 2 && acc[1] === ':') acc += '\\';
        out.push({ label: p, path: acc });
    }
    return out;
}

async function loadAnalyze(path) {
    const req = ++analyzeReq;
    analyzeLoading = true;
    analyzeError = '';
    analyzeTab = 'tree';
    analyzeSelected.clear();
    renderAnalyze();
    try {
        const node = await QDF.analyze(path || '', 3);
        if (req !== analyzeReq) return;
        analyzeNode = node || null;
    } catch (e) {
        if (req === analyzeReq) analyzeError = String(e && e.message ? e.message : e);
    } finally {
        if (req === analyzeReq) {
            analyzeLoading = false;
            renderAnalyze();
        }
    }
}

function renderAnalyze() {
    if (analyzeDrives === null) {
        analyzeDrives = [];
        QDF.analyzeDrives().then((d) => {
            analyzeDrives = arr(d);
            if (tab === 'analyze') renderAnalyze();
        }).catch(() => {});
    }
    if (analyzeTab === 'tree' && !analyzeNode && !analyzeLoading && !analyzeError) {
        loadAnalyze('');
        return;
    }

    const scroll = $('analyzeScroll');
    const node = analyzeNode;
    const totalText = node
        ? `${fmtCount(node.Files)} ${T.itemSuffix || ''} · ${fmtSize(node.Size)}`
        : (T.allDisks || '所有磁盘');
    const dirs = node ? arr(node.Children).filter((c) => c.IsDir).slice(0, 20) : [];
    const dirList = dirs.map((c) => `<button class="an-dir-row" data-action="an-drill" data-path="${esc(c.Path)}">
        <span class="an-dir-caret">›</span>
        <span class="an-dir-name">${esc(c.Name)}</span>
        <span class="an-dir-size">${esc(fmtSize(c.Size))}</span>
    </button>`).join('');

    const tabs = [
        ['tree', T.anCurrent || '当前目录'],
        ['largest', T.anLargest || '最大文件'],
        ['orphans', T.orphanHeading || '卸载残留'],
    ].map(([k, label]) => `<button class="an-tab ${analyzeTab === k ? 'on' : ''}"
        data-action="an-tab" data-tab="${k}">${esc(label)}</button>`).join('');

    const crumbs = analyzeCrumbs(node ? node.Path : '');
    const crumbHtml = crumbs.map((c, i) =>
        `<button class="an-crumb" data-action="an-crumb" data-path="${esc(c.path)}">${esc(c.label)}</button>` +
        (i < crumbs.length - 1 ? '<span class="an-sep">›</span>' : '')
    ).join('');

    scroll.innerHTML = `<div class="an-wrap">
        <aside class="an-side">
            <div class="an-planet" aria-hidden="true"></div>
            <div class="an-total">${esc(totalText)}</div>
            <div class="an-side-tabs">${tabs}</div>
            <div class="an-dir-list">${dirList}</div>
        </aside>
        <section class="an-main">
            <div class="an-top">
                <div class="an-crumbs">${crumbHtml}</div>
                <div class="an-meta">${analyzeMeta(node)}</div>
                <div class="an-tools">
                    <button class="btn small ghost ${analyzeMulti ? 'on' : ''}" data-action="an-multi">${esc(T.anMulti || '多选')}</button>
                    <button class="btn small ghost" data-action="an-refresh">${esc(T.refreshButton || '刷新')}</button>
                </div>
            </div>
            <div class="an-body">${analyzeBody(node)}</div>
        </section>
    </div>`;

    renderAnalyzeFooter();
    if (analyzeTab === 'tree' && node) requestAnimationFrame(drawTreemap);
}

function analyzeMeta(node) {
    if (!node) return '';
    const drive = arr(analyzeDrives).find((d) => String(node.Path).toUpperCase().startsWith(String(d.Name).toUpperCase()));
    const parts = [`${T.anFileSize || '文件'} ${fmtSize(node.Size)}`];
    if (drive) parts.push(`${T.anUsed || '已用'} ${fmtSize(drive.Total - drive.Free)} / ${fmtSize(drive.Total)}`);
    return parts.map(esc).join(' · ');
}

function analyzeBody(node) {
    if (analyzeLoading) {
        return `<div class="an-empty"><div class="an-empty-title">${esc(T.anLoading || '正在扫描…')}</div><div class="an-empty-sub">${esc(T.anScanNote || '只读扫描，不修改任何文件。')}</div></div>`;
    }
    if (analyzeError) {
        return `<div class="an-empty"><div class="an-empty-title">${esc(T.anError || '读取失败')}</div><div class="an-empty-sub">${esc(analyzeError)}</div></div>`;
    }
    if (analyzeTab === 'orphans') return orphanBody();
    if (analyzeTab === 'largest') return largestBody(node);
    if (!node) return driveBody();
    return `<div class="tm" id="tmBox"></div>`;
}

function driveBody() {
    const drives = arr(analyzeDrives);
    if (!drives.length) {
        return `<div class="an-empty"><div class="an-empty-title">${esc(T.anNoDrive || '没有找到磁盘')}</div></div>`;
    }
    return `<div class="drive-grid">${drives.map((d) => {
        const pct = d.Total ? Math.round(((d.Total - d.Free) / d.Total) * 100) : 0;
        return `<button class="drive-card" data-action="an-drive" data-path="${esc(d.Path)}">
            <span class="drive-name">${esc(d.Name)}</span>
            <span class="drive-free">${esc(fmtSize(d.Free))} ${esc(T.anFree || '可用')}</span>
            <span class="bar"><i style="width:${pct}%"></i></span>
            <span class="drive-total">${esc(fmtSize(d.Total - d.Free))} / ${esc(fmtSize(d.Total))}</span>
        </button>`;
    }).join('')}</div>`;
}

function largestBody(node) {
    const files = arr(node && node.Largest).slice(0, 120);
    if (!files.length) {
        return `<div class="an-empty"><div class="an-empty-title">${esc(T.anNoLargest || '没有找到大文件')}</div></div>`;
    }
    return `<div class="card lfiles">${files.map((f) => `<div class="lfile-row"
        data-action="an-select" data-path="${esc(f.Path)}" data-dir="0">
        <span class="lfile-name">${esc(f.Name)}</span>
        <span class="lfile-path">${esc(f.Path)}</span>
        <span class="lfile-size">${esc(fmtSize(f.Size))}</span>
    </div>`).join('')}</div>`;
}

function orphanBody() {
    const cands = arr(orphanResult && orphanResult.Candidates);
    if (!orphanResult) {
        return `<div class="an-empty">
            <div class="an-empty-title">${esc(T.orphanEmptyTitle || '还没有扫描')}</div>
            <div class="an-empty-sub">${esc(T.orphanEmptySub || '扫描 AppData 下可能属于已卸载软件的目录，只报告不删除。')}</div>
        </div>`;
    }
    const rows = cands.length
        ? cands.map((c) => `<div class="afile">
            <div class="afile-path">${esc(c.Path)}</div>
            <div class="afile-bar">
                <span class="afile-size">${esc(c.SizeText || fmtSize(c.Size))}${c.SizeComplete ? '' : ' +'}</span>
            </div>
        </div>`).join('')
        : `<div class="empty"><div class="empty-title">${esc(T.orphanEmpty || '')}</div></div>`;
    return `<div class="an-summary">${esc(T.orphanTotal || '')} ${cands.length} ${esc(T.itemSuffix || '')} · ${esc(orphanResult.TotalSizeText || fmtSize(orphanResult.TotalSize))} · ${esc(T.orphanNote || '')}</div>
        <div class="card"><div style="padding:6px 18px">${rows}</div></div>`;
}

function renderAnalyzeFooter() {
    const f = $('analyzeFooter');
    if (analyzeTab === 'orphans') {
        const btn = `<button class="btn ghost" data-action="scan-orphans" ${orphanState === 'scanning' ? 'disabled' : ''}>${esc(orphanState === 'scanning' ? (T.statusScanning || '') : (T.orphanScan || ''))}</button>`;
        f.innerHTML = `<div class="footer-summary"><span class="footer-note">${orphanResult ? esc(T.scannedAt || '') + ' ' + esc(fmtWhen(orphanResult.ScannedAt)) : ''}</span></div>${btn}`;
        return;
    }
    const n = analyzeSelected.size;
    const bytes = [...analyzeSelected].reduce((s, p) => {
        const hit = analyzeByPath(p);
        return s + (hit ? Number(hit.Size) || 0 : 0);
    }, 0);
    const summary = analyzeMulti && n
        ? `<span class="footer-lead">${esc(T.selectedPrefix || '')} ${n} ${esc(T.itemSuffix || '')} · ${esc(fmtSize(bytes))}</span>`
        : `<span class="footer-note">${esc(T.anHint || '右键可复制路径、移到回收站等')}</span>`;
    const actions = analyzeMulti && n
        ? `<button class="btn ghost" data-action="an-copy">${esc(T.anCopyPath || '复制路径')}</button>
           <button class="btn ghost" data-action="an-recycle">${esc(T.anRecycle || '移到回收站')}</button>`
        : '';
    f.innerHTML = `<div class="footer-summary">${summary}</div>${actions}`;
}

function analyzeByPath(path) {
    return arr(analyzeNode && analyzeNode.Children).find((c) => c.Path === path) ||
        arr(analyzeNode && analyzeNode.Largest).find((f) => f.Path === path) || null;
}

function squarify(items, W, H) {
    const total = items.reduce((s, i) => s + i.size, 0) || 1;
    const area0 = W * H;
    const rest = items.slice();
    const out = [];
    let x = 0, y = 0, w = W, h = H;
    const rowArea = (row) => row.reduce((s, i) => s + i.size, 0) / total * area0;
    const worst = (row, short, area) => {
        const sum = row.reduce((s, i) => s + i.size, 0) || 1;
        const thickness = area / short;
        let v = 0;
        for (const it of row) {
            const len = (it.size / sum) * short;
            if (len <= 0) continue;
            v = Math.max(v, thickness / len, len / thickness);
        }
        return v;
    };
    while (rest.length) {
        const row = [rest.shift()];
        const short = Math.min(w, h);
        let score = worst(row, short, rowArea(row));
        while (rest.length) {
            const cand = row.concat(rest[0]);
            const next = worst(cand, short, rowArea(cand));
            if (next > score) break;
            row.push(rest.shift());
            score = next;
        }
        const sum = row.reduce((s, i) => s + i.size, 0) || 1;
        const ra = sum / total * area0;
        if (w >= h) {
            const colW = ra / h;
            let yy = y;
            for (const it of row) {
                const hh = it.size / sum * h;
                out.push({ item: it, x, y: yy, w: colW, h: hh });
                yy += hh;
            }
            x += colW; w -= colW;
        } else {
            const rowH = ra / w;
            let xx = x;
            for (const it of row) {
                const ww = it.size / sum * w;
                out.push({ item: it, x: xx, y, w: ww, h: rowH });
                xx += ww;
            }
            y += rowH; h -= rowH;
        }
    }
    return out;
}

function drawTreemap() {
    const box = $('tmBox');
    if (!box || !analyzeNode) return;
    const rect = box.getBoundingClientRect();
    const W = Math.floor(rect.width), H = Math.floor(rect.height);
    if (W < 40 || H < 40) return;
    const all = arr(analyzeNode.Children).filter((c) => Number(c.Size) > 0);
    const total = all.reduce((s, c) => s + (Number(c.Size) || 0), 0) || 1;
    // Below 0.6% a cell is unreadable; fold those into one "其他" tile.
    const floor = total * 0.006;
    const main = all.filter((c) => Number(c.Size) >= floor);
    const rest = all.filter((c) => Number(c.Size) < floor);
    const items = main.map((c) => ({ node: c, size: Number(c.Size) || 0 }));
    if (rest.length) {
        const restSize = rest.reduce((s, c) => s + (Number(c.Size) || 0), 0);
        items.push({
            node: { Name: `其他 (${rest.length})`, Path: '', Size: restSize, IsDir: false },
            size: restSize,
        });
    }
    items.sort((a, b) => b.size - a.size);
    const cells = squarify(items.slice(0, 60), W, H);
    box.innerHTML = cells.map((r) => {
        const n = r.item.node;
        const cls = ['tm-cell'];
        if (analyzeSelected.has(n.Path)) cls.push('selected');
        if (r.w < 64 || r.h < 38) cls.push('tiny');
        let hash = 0;
        for (const ch of String(n.Name)) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
        const bg = TM_COLORS[hash % TM_COLORS.length];
        return `<div class="${cls.join(' ')}"
            style="left:${r.x}px;top:${r.y}px;width:${Math.max(1, r.w - 2)}px;height:${Math.max(1, r.h - 2)}px;background:${bg}"
            data-action="an-cell" data-path="${esc(n.Path)}" data-dir="${n.IsDir ? '1' : '0'}">
            <span class="tm-name">${esc(n.Name)}</span>
            <span class="tm-size">${esc(fmtSize(n.Size))}</span>
        </div>`;
    }).join('');
}

function onAnalyzeCell(el) {
    const path = el.dataset.path;
    if (!path) return;
    if (analyzeMulti) { toggleAnalyzeSelect(path); return; }
    if (el.dataset.dir === '1') loadAnalyze(path);
}

function toggleAnalyzeSelect(path) {
    analyzeMulti = true;
    if (analyzeSelected.has(path)) analyzeSelected.delete(path);
    else analyzeSelected.add(path);
    renderAnalyze();
}

async function copySelected() {
    if (!analyzeSelected.size) return;
    try {
        await QDF.copyText([...analyzeSelected].join('\n'));
    } catch (e) {
        showError(String(e));
    }
}

async function recycleSelected() {
    if (!analyzeSelected.size) return;
    const n = analyzeSelected.size;
    if (!confirm(`将 ${n} 项移到回收站？可以在回收站还原。`)) return;
    const errors = [];
    for (const p of [...analyzeSelected]) {
        try { await QDF.recyclePath(p); } catch (e) { errors.push(String(e)); }
    }
    analyzeSelected.clear();
    if (errors.length) showError(errors.join('\n'));
    loadAnalyze(analyzeNode ? analyzeNode.Path : '');
}

function showCtxMenu(x, y, path, isDir) {
    const menu = $('ctxMenu');
    if (!menu || !path) return;
    analyzeCtxNode = { path, isDir };
    menu.innerHTML = `<button data-action="ctx-copy">${esc(T.anCopyPath || '复制路径')}</button>
        <button data-action="ctx-reveal">${esc(T.anReveal || '在资源管理器中显示')}</button>
        <button data-action="ctx-recycle" class="danger">${esc(T.anRecycle || '移到回收站')}</button>`;
    menu.classList.remove('hidden');
    const w = menu.offsetWidth || 180;
    const h = menu.offsetHeight || 110;
    menu.style.left = Math.min(x, window.innerWidth - w - 8) + 'px';
    menu.style.top = Math.min(y, window.innerHeight - h - 8) + 'px';
}

function hideCtxMenu() {
    const menu = $('ctxMenu');
    if (menu) menu.classList.add('hidden');
}

document.addEventListener('contextmenu', (e) => {
    const el = e.target.closest('.tm-cell, .an-dir-row, .lfile-row');
    if (!el) return;
    e.preventDefault();
    showCtxMenu(e.clientX, e.clientY, el.dataset.path, el.dataset.dir === '1');
});

document.addEventListener('click', (e) => {
    if (!e.target.closest('#ctxMenu')) hideCtxMenu();
});

let analyzeResizeBound = false;
function bindAnalyzeResize() {
    if (analyzeResizeBound) return;
    analyzeResizeBound = true;
    let t = null;
    window.addEventListener('resize', () => {
        clearTimeout(t);
        t = setTimeout(() => {
            if (tab === 'analyze' && analyzeTab === 'tree') drawTreemap();
        }, 120);
    });
}

/* ---------------- 记录页 ---------------- */

async function renderHistory() {
    const scroll = $('historyScroll');
    if (historyRows === null) {
        try {
            historyRows = arr(await QDF.history(50));
        } catch (e) {
            historyRows = [];
            showError(String(e));
        }
    }
    const rows = historyRows;

    const list = rows.length
        ? rows.map((h, i) => `<div class="hrow" data-action="open-receipt" data-idx="${i}">
            <span class="when">${esc(fmtWhen(h.CompletedAt || h.StartedAt))}</span>
            <span class="freed">${esc(h.BytesFreedText || '0 B')}</span>
            <span class="rules">${esc(operationState(h.State))} · ${esc(arr(h.SelectedRuleIds).map(ruleLabel).join('、'))}</span>
            ${Number(h.FailedCount) > 0 ? `<span class="failed">${esc(T.summaryFailed || '')} ${Number(h.FailedCount)}</span>` : ''}
        </div>`).join('')
        : `<div class="card empty"><div class="empty-title">${esc(T.noItems || '')}</div></div>`;

    const totalFreed = rows.reduce((s, h) => s + (Number(h.BytesFreed) || 0), 0);
    scroll.innerHTML = `<div class="hero">
        <div class="hero-label">${esc(T.heroTotalFreed || '')}</div>
        <div class="hero-value hero-sm">${esc(fmtSize(totalFreed))}</div>
        <div class="hero-sub">${rows.length} ${esc(T.historyCount || '')}</div>
    </div>
    <div class="stack">${list}</div>
    <div id="receiptBox"></div>`;

    $('historyFooter').innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.historyHeading || '')}</span></div>
        <button class="btn ghost" data-action="open-whitelist">${esc(T.whitelistButton || '')}</button>
        <button class="btn ghost" data-action="open-recyclebin">${esc(T.openRecycleBin || '')}</button>
        <button class="btn ghost" data-action="open-logs">${esc(T.logsButton || '')}</button>`;

    if (receiptOpen !== null) await renderReceipt(receiptOpen);
}

async function renderReceipt(idx) {
    const h = arr(historyRows)[idx];
    const box = $('receiptBox');
    if (!h || !box) return;
    const path = h.ReceiptPath;
    receiptOpen = idx;

    let detail = '';
    try {
        const r = await QDF.receipt(path);
        const s = r.Summary || {};
        const failures = arr(s.Failures);
        const kv = [
            ['操作状态', operationState(s.State), s.State && s.State !== 'Completed'],
            ['结果未知', String(s.UnknownCount || 0), Number(s.UnknownCount) > 0],
            [T.summaryProcessed, String(s.SuccessfulCount || 0), false],
            [T.summaryRecycled, s.BytesRecycledText || '0 B', false],
            [T.summaryFailed, String(s.FailedCount || 0), Number(s.FailedCount) > 0],
        ];
        detail = `<div class="kv">${kv.map(([k, v, d]) =>
            `<div><dt>${esc(k)}</dt><dd class="${d ? 'danger' : ''}">${esc(v)}</dd></div>`).join('')}</div>`;
        if (s.Error) detail += '<div class="footer-note">' + esc(s.Error) + '</div>';
        detail += arr(r.Items).slice(0, 200).map((item) => '<div class="fail-row"><span class="p">' + esc(item.Path) + '</span><span class="why">' + esc(({Deleted:'已删除',Recycled:'已移入回收站',Failed:'未完成',Unknown:'结果未知',DryRun:'仅预览'})[item.Status] || item.Status || '旧版候选记录') + '</span></div>').join('');
        if (r.ReceiptTruncated || arr(r.Items).length > 200) detail += '<div class="footer-note">界面仅展示部分明细，完整逐项记录保存在同名 .jsonl 文件中。</div>';
        if (failures.length) {
            detail += `<div class="footer-note">${esc(T.summaryFailed || '')}（${failures.length}）</div>` +
                failures.slice(0, 30).map((f) => `<div class="fail-row">
                    <span class="r">${esc(ruleLabel(f.RuleId))}</span>
                    <span class="p">${esc(f.Path)}</span>
                    <span class="why">${esc(f.Reason || '')}</span>
                </div>`).join('');
        }
    } catch (e) {
        detail = `<div class="footer-note">${esc(String(e))}</div>`;
    }

    box.innerHTML = `<div class="card receipt">
        <div class="group-head">
            <span class="group-title">${esc(T.receiptPath || '')}</span>
            <span class="group-meta">${esc(fmtWhen(h.CompletedAt || h.StartedAt))} · ${esc(h.BytesFreedText || '0 B')}</span>
            <span class="group-tools"><button class="btn small ghost" data-action="close-receipt">${esc(T.closeButton || '')}</button></span>
        </div>
        <div style="padding:14px 18px">
            <div class="receipt-path">${esc(path || '')}</div>
            ${detail}
        </div>
    </div>`;
}

/* ---------------- 状态页 ---------------- */

function fmtRate(bytes) { return fmtSize(bytes) + '/s'; }

function fmtUptime(sec) {
    const s = Math.max(0, Math.floor(Number(sec) || 0));
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d) return `${d}天${h}小时`;
    if (h) return `${h}小时${m}分钟`;
    return `${m}分钟`;
}

function pushHist(key, value) {
    const a = statusHist[key];
    a.push(Number(value) || 0);
    while (a.length > 24) a.shift();
}

/* 柱状 sparkline：只表达趋势，不画坐标轴——和 Mole 的极简图表一致 */
function spark(values, max) {
    if (!values.length) return '';
    const top = Math.max(Number(max) || 0, ...values, 1);
    return `<div class="spark">${values.map((v) =>
        `<i style="height:${Math.max(3, Math.min(100, (v / top) * 100))}%"></i>`).join('')}</div>`;
}

function startStatusPolling() {
    stopStatusPolling();
    loadStatus();
    statusTimer = setInterval(loadStatus, 3000);
}

function stopStatusPolling() {
    if (statusTimer) { clearInterval(statusTimer); statusTimer = null; }
}

async function loadStatus() {
    if (statusBusy) return;
    if (typeof document !== 'undefined' && document.hidden) return;
    statusBusy = true;
    try {
        const s = await QDF.status();
        if (s) {
            statusData = s;
            pushHist('cpu', s.CPUPercent);
            pushHist('mem', s.MemPercent);
            pushHist('net', (Number(s.NetRecvPerSec) || 0) + (Number(s.NetSentPerSec) || 0));
            if (tab === 'status') renderStatus();
        }
    } catch (e) {
        showError(String(e));
    } finally {
        statusBusy = false;
    }
}

function renderStatus() {
    const scroll = $('statusScroll');
    const f = $('statusFooter');
    if (!statusData) {
        scroll.innerHTML = `<div class="hero">
            <div class="hero-label">${esc(T.statusHeading || '系统状态')}</div>
            <div class="hero-value hero-sm">${esc(T.statusLoading || '正在读取系统状态…')}</div>
        </div>`;
        f.innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.statusLoading || '')}</span></div>`;
        return;
    }

    const s = statusData;
    const score = Number(s.HealthScore) || 0;
    const tone = score >= 85 ? 'safe' : score >= 60 ? 'warn' : 'danger';
    const disk = arr(s.Disks)[0] || {};
    const diskPct = Number(disk.UsedPercent) || 0;
    const battery = s.BatteryPresent
        ? `<div class="metric">${Number(s.BatteryPercent) || 0}<small>%</small></div>
           <div class="status-sub">${esc(s.BatteryCharging ? (T.statusCharging || '已接电') : (T.statusOnBattery || '电池供电'))}</div>
           <div class="bar"><i style="width:${Number(s.BatteryPercent) || 0}%"></i></div>`
        : `<div class="metric">—</div><div class="status-sub">${esc(T.statusUnavailable || '暂不可用')}</div>`;

    const procs = arr(s.TopProcesses);
    const procRows = procs.length
        ? procs.map((p) => `<div class="prow">
            <span class="pname">${esc(p.Name)}</span>
            <span class="pmem">${esc(fmtSize(p.Memory))}</span>
            <span class="pcpu">${Number(p.CPU || 0).toFixed(1)}%</span>
            <span class="ppid">${esc(String(p.PID))}</span>
          </div>`).join('')
        : `<div class="empty"><div class="empty-title">${esc(T.statusUnavailable || '暂不可用')}</div></div>`;

    scroll.innerHTML = `<div class="hero">
        <div class="hero-label">${esc(T.statusHealth || '健康度')}</div>
        <div class="hero-value ${tone}">${score}</div>
        <div class="hero-sub">${esc(s.HealthMessage || '')} · ${esc(T.statusUptime || '已运行')} ${esc(fmtUptime(s.UptimeSeconds))}</div>
        <div class="status-meta">${esc(s.Platform || '')} · ${esc(s.CPUModel || '')} · ${Number(s.CPUCores) || 0} 线程</div>
    </div>
    <div class="status-grid">
        <div class="card status-card">
            <h4>${esc(T.statusCPU || 'CPU')}</h4>
            <div class="metric">${Number(s.CPUPercent || 0).toFixed(0)}<small>%</small></div>
            ${spark(statusHist.cpu, 100)}
            <div class="status-sub">${esc(s.CPUModel || '')}</div>
        </div>
        <div class="card status-card">
            <h4>${esc(T.statusMemory || '内存')}</h4>
            <div class="metric">${Number(s.MemPercent || 0).toFixed(0)}<small>%</small></div>
            <div class="bar"><i style="width:${Number(s.MemPercent) || 0}%"></i></div>
            <div class="status-sub">${esc(fmtSize(s.MemUsed))} / ${esc(fmtSize(s.MemTotal))}</div>
        </div>
        <div class="card status-card">
            <h4>${esc(T.statusDisk || '磁盘')} ${esc(disk.Device || '')}</h4>
            <div class="metric">${esc(fmtSize(disk.Free))}<small>可用</small></div>
            <div class="bar"><i style="width:${diskPct}%"></i></div>
            <div class="status-sub">已用 ${esc(fmtSize(disk.Used))} / ${esc(fmtSize(disk.Total))}</div>
        </div>
        <div class="card status-card">
            <h4>${esc(T.statusNetwork || '网络')}</h4>
            <div class="metric">${esc(fmtRate(s.NetRecvPerSec || 0))}<small>下行</small></div>
            ${spark(statusHist.net, Math.max(...statusHist.net, 1))}
            <div class="status-sub">上行 ${esc(fmtRate(s.NetSentPerSec || 0))}</div>
        </div>
        <div class="card status-card">
            <h4>${esc(T.statusBattery || '电池')}</h4>
            ${battery}
        </div>
        <div class="card status-card">
            <h4>虚拟内存</h4>
            <div class="metric">${Number(s.SwapPercent || 0).toFixed(0)}<small>%</small></div>
            <div class="bar"><i style="width:${Number(s.SwapPercent) || 0}%"></i></div>
            <div class="status-sub">${esc(fmtSize(s.SwapUsed))} / ${esc(fmtSize(s.SwapTotal))}</div>
        </div>
    </div>
    <div class="card status-processes">
        <div class="group-head">
            <span class="group-title">${esc(T.statusProcesses || '进程')}</span>
            <span class="group-meta">${esc(T.statusProcessHint || '')}</span>
        </div>
        <div class="plist">
            <div class="phead"><span>名称</span><span>内存</span><span>CPU</span><span>PID</span></div>
            ${procRows}
        </div>
    </div>`;

    f.innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.statusHeading || '系统状态')} · ${esc(s.Hostname || '')}</span></div>
        <button class="btn ghost" data-action="refresh-status">${esc(T.statusRefresh || '刷新')}</button>`;
}

/* ---------------- 动作 ---------------- */

async function startScan() {
    if (scanState === 'scanning' || scanState === 'cleaning') return;
    scanState = 'scanning';
    scanSeen = [];
    selected = new Set();
    renderClean();
    try {
        const err = await QDF.scan([]);
        if (err) {
            showError(String(err));
            scanState = 'idle';
            renderClean();
        }
    } catch (e) {
        showError(String(e));
        scanState = 'idle';
        renderClean();
    }
}

function onScanProgress(ev) {
    scanSeen.push({ name: ev.ruleName || ev.ruleId || '', total: ev.total || 0 });
    if (scanState === 'scanning') renderClean();
    // 扫描线的行程要用容器的真实高度，写死像素会在长清单上扫不到底。
    const sweep = $('scanSweep');
    if (sweep) sweep.style.setProperty('--sweep-h', sweep.scrollHeight + 'px');
}

function onCleanProgress(ev) {
    cleanProgress = ev || null;
    if (scanState === 'cleaning') renderClean();
}

function onScanDone(result) {
    if (!result || result.type !== 'result') {
        scanState = 'idle';
        renderClean();
        return;
    }
    scanResult = result;
    selected = new Set(liveCategories().filter((c) => c.DefaultSelected).map((c) => c.Id));
    scanState = 'review';
    receiptOpen = null;
    historyRows = null;           // 新的操作会写进日志，下次进记录页重读
    renderClean();
    staggerRules();               // 扫描结果从上往下逐行就位，像一条条查过之后摆上来
}

/* 列表顺序显示（リスト順次表示）——每行从下方位移就位，间隔 50ms。
   只跑一次：切页签或重新勾选都走 renderClean()，不会重播，避免变成噪音。 */
function staggerRules() {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const rows = document.querySelectorAll('.rule');
    rows.forEach((row, i) => {
        row.classList.remove('enter');
        void row.offsetWidth;                 // 强制回流，动画才能从零重播
        row.style.animationDelay = Math.min(i * 50, 500) + 'ms';
        row.classList.add('enter');
        row.addEventListener('animationend', () => {
            row.classList.remove('enter');
            row.style.animationDelay = '';
        }, { once: true });
    });
}

async function startClean() {
    if (scanState !== 'review') return;
    if (!selected.size) return;
    const cats = selectedLive();
    const delBytes = cats.filter((c) => c.Action === 'delete').reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);
    const recBytes = cats.filter((c) => c.Action === 'recycle').reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);

    const lines = [T.confirmQuestion || ''];
    if (delBytes) lines.push(`${T.confirmPermanent}：${fmtSize(delBytes)}（不可还原）`);
    if (recBytes) lines.push(`${T.confirmRecycle}：${fmtSize(recBytes)}（可在回收站还原，不立即释放空间）`);
    if (!confirm(lines.join('\n\n'))) return;

    scanState = 'cleaning';
    cleanProgress = null;
    renderClean();
    try {
        const err = await QDF.clean([...selected]);
        if (err) {
            showError(String(err));
            scanState = 'review';
            renderClean();
        }
    } catch (e) {
        showError(String(e));
        scanState = 'review';
        renderClean();
    }
}

function onCleanDone(result) {
    if (!result || result.type !== 'result') {
        scanState = 'review';
        renderClean();
        return;
    }
    cleanResult = result;
    cleanProgress = null;
    if (result.State && result.State !== 'Completed') showError(operationState(result.State) + (result.Error ? '：' + result.Error : '；请查看记录页。'));
    scanState = 'done';
    scanResult = null;            // 扫过的内容已经被处理，旧结果不再可信
    selected = new Set();
    historyRows = null;
    renderClean();
    playDoneExit();
}

/* 缩小淡出退场（縮小フェード退場）——已处理的规则逐条收敛消失，底部「已释放」
   同步累加。位置保持不变，所以下面的行不会突然跳上来。 */
function playDoneExit() {
    const list = $('doneList');
    const tally = $('doneTally');
    // RuleResults is absent (older receipt) or the list never rendered: nothing
    // to play. Guarding here also keeps the function safe if the DOM is stubbed.
    if (!list || typeof list.querySelectorAll !== 'function') return;
    // 上一次退场还没跑完就重渲染时，先撤掉所有旧计时器，
    // 否则多个动画叠加，行会在错误的时间点消失。
    doneExitTimers.forEach(clearTimeout);
    doneExitTimers = [];
    const rows = [...list.querySelectorAll('.done-row')];
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    if (reduce || !rows.length) {
        rows.forEach((row) => row.classList.add('gone'));
        if (tally) tally.textContent = (cleanResult && cleanResult.BytesFreedText) || '0 B';
        return;
    }

    // 逐条取后端给的字节数。只累加永久删除的部分——回收站文件仍占空间，
    // 把 BytesRecycled 算进"已释放"会和 hero 的 BytesFreed 矛盾。
    const per = arr(cleanResult && cleanResult.RuleResults);
    const freed = rows.map((row) => {
        const it = per.find((x) => String(x.RuleId) === String(row.dataset.ruleId));
        return Number(it && it.BytesFreed) || 0;
    });
    const finalText = (cleanResult && cleanResult.BytesFreedText) || fmtSize(freed.reduce((s, b) => s + b, 0));

    rows.forEach((row, i) => {
        doneExitTimers.push(setTimeout(() => {
            row.classList.add('gone');
            // 只从已累加值滚到下一个值，最后一帧自然落在总数上。
            // 不要再用 finalText 覆盖：那会和动画算出的值不一致，出现回跳。
            if (tally) animateNumber(tally, freed.slice(0, i).reduce((s, b) => s + b, 0), freed.slice(0, i + 1).reduce((s, b) => s + b, 0), 400);
        }, 120 + i * 220));
    });
    // 最后一条落地后补一次，避免浮点误差让末位差一点
    doneExitTimers.push(setTimeout(() => {
        if (tally) tally.textContent = finalText;
    }, 120 + rows.length * 220 + 420));
}

/* 数字滚动：ease-out 让数值快速冲到接近目标再缓缓停下，比线性更有"称重"感。 */
function animateNumber(el, from, to, duration, done) {
    if (from === to) { el.textContent = fmtSize(to); if (done) done(); return; }
    const start = performance.now();
    (function tick(now) {
        const p = Math.min((now - start) / duration, 1);
        const e = 1 - Math.pow(1 - p, 3);
        el.textContent = fmtSize(from + (to - from) * e);
        if (p < 1) requestAnimationFrame(tick);
        else if (done) done();
    })(start);
}

/* ---------------- 已卸载残留 / 回收站 / 白名单 ---------------- */

async function startOrphanScan() {
    if (orphanState === 'scanning') return;
    orphanState = 'scanning';
    renderAnalyze();
    try {
        const err = await QDF.orphans();
        if (err) {
            showError(String(err));
            orphanState = orphanResult ? 'done' : 'idle';
            renderAnalyze();
        }
    } catch (e) {
        showError(String(e));
        orphanState = orphanResult ? 'done' : 'idle';
        renderAnalyze();
    }
}

function onOrphansDone(result) {
    if (!result || result.type !== 'result') {
        orphanState = orphanResult ? 'done' : 'idle';
        renderAnalyze();
        return;
    }
    orphanResult = result;
    orphanState = 'done';
    renderAnalyze();
}

async function emptyRecycleBin() {
    if (!confirm(T.emptyRecycleBinConfirm || '回收站里的文件将被永久删除，无法恢复。确定清空吗？')) return;
    try {
        const err = await QDF.emptyRecycleBin();
        if (err) showError(String(err));
    } catch (e) {
        showError(String(e));
    }
}

function onRecycleBinDone(result) {
    if (!result || result.type !== 'result') return;
    if (result.Error) {
        showError(result.Error);
        return;
    }
    const size = result.TotalSizeText || '0 B';
    showError(`${T.emptyRecycleBinDone || '回收站已清空'}：${Number(result.ItemCount) || 0} ${T.itemSuffix || ''} · ${size}`);
    historyRows = null;
}

function toggleDetail(ruleEl) {
    const existing = ruleEl.querySelector('.rule-files');
    if (existing) { existing.remove(); return; }
    const cat = liveCategories().find((c) => c.Id === ruleEl.dataset.ruleId);
    if (!cat) return;
    const rows = arr(cat.Files).slice(0, 200).map((f) => `<div class="rule-file">
        <span class="p">${esc(f.Path)}</span><span class="s">${esc(fmtSize(f.Size))}</span></div>`).join('');
    const more = (cat.DetailsTruncated || cat.ItemCount > 200)
        ? `<div class="rule-file more"><span class="p">${esc(T.detailsTruncated || '')}</span></div>` : '';
    ruleEl.insertAdjacentHTML('beforeend', `<div class="rule-files">${rows}${more}</div>`);
}

const ACTIONS = {
    scan: () => startScan(),
    rescan: () => { historyRows = null; startScan(); },
    cancel: async () => { try { await QDF.cancel(); showError('正在停止，请等待当前文件处理及回执保存完成。'); } catch (e) { showError(String(e)); } },
    clean: () => startClean(),
    'group-all': (el) => setGroup(el.dataset.group, true),
    'group-none': (el) => setGroup(el.dataset.group, false),
    'toggle-detail': (el) => toggleDetail(el.closest('.rule')),
    'toggle-cat': (el) => { const b = el.closest('.cat-block'); if (b) b.classList.toggle('collapsed'); },
    'go-analyze': () => showTab('analyze'),
    'go-scan': () => { showTab('clean'); startScan(); },
    'an-tab': (el) => { analyzeTab = el.dataset.tab; analyzeSelected.clear(); renderAnalyze(); },
    'an-drill': (el) => loadAnalyze(el.dataset.path),
    'an-drive': (el) => loadAnalyze(el.dataset.path),
    'an-crumb': (el) => {
        const p = el.dataset.path;
        analyzeSelected.clear();
        if (!p) { analyzeTab = 'drives'; analyzeNode = null; renderAnalyze(); }
        else loadAnalyze(p);
    },
    'an-refresh': () => loadAnalyze(analyzeNode ? analyzeNode.Path : ''),
    'an-multi': () => { analyzeMulti = !analyzeMulti; if (!analyzeMulti) analyzeSelected.clear(); renderAnalyze(); },
    'an-cell': (el) => onAnalyzeCell(el),
    'an-select': (el) => toggleAnalyzeSelect(el.dataset.path),
    'an-copy': () => copySelected(),
    'an-recycle': () => recycleSelected(),
    'win-min': () => QDF.windowMinimise(),
    'win-max': () => QDF.windowToggleMaximise(),
    'win-close': () => QDF.windowClose(),
    'ctx-copy': () => { if (analyzeCtxNode) QDF.copyText(analyzeCtxNode.path); hideCtxMenu(); },
    'ctx-reveal': () => { if (analyzeCtxNode) QDF.revealPath(analyzeCtxNode.path); hideCtxMenu(); },
    'ctx-recycle': async () => {
        const node = analyzeCtxNode;
        hideCtxMenu();
        if (!node) return;
        if (!confirm(`将「${node.path}」移到回收站？可以在回收站还原。`)) return;
        try {
            await QDF.recyclePath(node.path);
            loadAnalyze(analyzeNode ? analyzeNode.Path : '');
        } catch (e) { showError(String(e)); }
    },
    'scan-orphans': () => startOrphanScan(),
    'empty-recyclebin': () => emptyRecycleBin(),
    'open-whitelist': () => QDF.openPath('whitelist'),
    'open-recyclebin': () => QDF.openPath('recyclebin'),
    'open-logs': () => QDF.openPath('logs'),
    'open-receipt': (el) => renderReceipt(Number(el.dataset.idx)),
    'close-receipt': () => { receiptOpen = null; const b = $('receiptBox'); if (b) b.innerHTML = ''; },
    'refresh-status': () => loadStatus(),
};

function setGroup(action, on) {
    liveCategories().filter((c) => c.Action === action).forEach((c) => {
        if (on) selected.add(c.Id); else selected.delete(c.Id);
    });
    renderClean();
}

/* ---------------- 事件绑定（委托，避免每次重渲染重挂） ---------------- */

document.addEventListener('click', (e) => {
    const tabBtn = e.target.closest('.tab');
    if (tabBtn) { showTab(tabBtn.dataset.tab); return; }

    const el = e.target.closest('[data-action]');
    if (!el) return;
    const fn = ACTIONS[el.dataset.action];
    if (!fn) return;
    // 点规则行上的「明细」按钮时不要连带切换勾选
    if (el.dataset.action === 'toggle-rule' && e.target.closest('.rule-detail')) return;
    e.preventDefault();
    fn(el);
});

document.addEventListener('change', (e) => {
    const cb = e.target.closest('input[type=checkbox][data-rule-id]');
    if (!cb) return;
    if (cb.checked) selected.add(cb.dataset.ruleId); else selected.delete(cb.dataset.ruleId);
    const justChecked = cb.checked;
    renderClean();
    // 焦点光环（フォーカスハロー）：勾上的那一行闪光，表示「这一项你确认过了」。
    // 必须等 innerHTML 重渲染后再加 class，否则会被立刻抹掉。
    if (justChecked) pulseRule(cb.dataset.ruleId);
});

/* 光环只在看得见的前提下闪——reduced-motion 下降级成一行不动的静态描边。 */
function pulseRule(ruleId) {
    const row = document.querySelector(`.rule[data-rule-id="${CSS.escape(ruleId)}"]`);
    if (!row) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
        row.style.boxShadow = 'inset 0 0 0 2px var(--safe)';
        return;
    }
    row.classList.remove('verified');
    void row.offsetWidth;                 // 强制回流，让动画能从零重播
    row.classList.add('verified');
    row.addEventListener('animationend', () => row.classList.remove('verified'), { once: true });
}

$('errorDismiss').addEventListener('click', () => $('errorBanner').classList.add('hidden'));

/* ---------------- 文案 ---------------- */

function applyStrings() {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
        const v = T[el.dataset.i18n];
        if (v !== undefined) el.textContent = v;
    });
    document.title = T.appTitle || '清道夫';
}

/* ---------------- 启动 ---------------- */

(async function init() {
    try {
        T = JSON.parse(await QDF.strings());
    } catch (e) {
        T = {};
        showError('文案加载失败：' + e);
    }
    try {
        ruleNames = Object.fromEntries(arr(JSON.parse(await QDF.rules()).rules).map((r) => [r.id, r.name]));
    } catch (e) {
        // 历史/回执退回显示原始 id，不影响主流程
        console.warn('[清道夫] rules.json 读取失败，历史将显示规则 id', e);
    }
    applyStrings();

    QDF.on('scan:progress', onScanProgress);
    QDF.on('scan:done', onScanDone);
    QDF.on('clean:progress', onCleanProgress);
    QDF.on('clean:done', onCleanDone);
    QDF.on('orphans:progress', () => { if (orphanState === 'scanning') renderAnalyze(); });
    QDF.on('orphans:done', onOrphansDone);
    QDF.on('recycle-bin:done', onRecycleBinDone);
    QDF.on('app:error', onTaskError);
    QDF.on('app:stopping', (message) => showError(message));
    QDF.on('app:cancelled', () => { scanState = 'idle'; scanResult = null; selected = new Set(); renderClean(); });

    bindAnalyzeResize();
    showTab('clean');
})();
