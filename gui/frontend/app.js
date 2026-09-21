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
let historyRows = null;
let receiptOpen = null;       // 当前展开的回执路径
let ruleNames = {};           // 规则 id → 中文名（历史与回执里只有 id）

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

const RENDER = { clean: renderClean, analyze: renderAnalyze, history: renderHistory };

function showTab(next) {
    tab = next;
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
    <div class="card"><div class="pad">${bar}<div class="checklist">${items}${left}</div></div></div>`;
}

function viewCleaning() {
    return `<div class="hero">
        <div class="hero-label">${esc(T.statusCleaning || '')}</div>
        <div class="hero-sub">${esc(T.cleaningNow || '')}</div>
    </div>
    <div class="card"><div class="pad"><div class="bar indet"><i></i></div></div></div>`;
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
        f.innerHTML = `<div class="footer-summary"><span class="footer-lead">${esc(T.statusCleaning || '')}</span></div>`;
    } else {
        const r = cleanResult || {};
        const failed = Number(r.FailedCount) || 0;
        f.innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.summaryProcessed || '')} ${Number(r.SuccessfulCount) || 0} ${esc(T.itemSuffix || '')}${failed ? ` · ${esc(T.summaryFailed || '')} ${failed}` : ''}</span></div>
            <button class="btn ghost" data-action="open-recyclebin">${esc(T.openRecycleBin || '')}</button>
            <button class="btn primary" data-action="scan">${esc(T.scanButton || '')}</button>`;
    }
}

/* ---------------- 分析页 ---------------- */

function renderAnalyze() {
    const scroll = $('analyzeScroll');
    const lf = arr(scanResult && scanResult.LargeFiles);

    if (!scanResult) {
        scroll.innerHTML = `<div class="card empty">
            <div class="empty-title">${esc(T.analyzeEmptyTitle || '')}</div>
            <div>${esc(T.analyzeEmptySub || '')}</div>
            <div class="empty-actions"><button class="btn primary" data-action="go-scan">${esc(T.goScan || '')}</button></div>
        </div>`;
        $('analyzeFooter').innerHTML = '';
        return;
    }

    const max = lf.reduce((m, f) => Math.max(m, Number(f.Size) || 0), 0) || 1;
    const total = lf.reduce((s, f) => s + (Number(f.Size) || 0), 0);

    const rows = lf.length
        ? lf.map((f) => `<div class="afile">
            <div class="afile-path">${esc(f.Path)}</div>
            <div class="afile-bar">
                <div class="bar"><i style="width:${Math.max(2, Math.round((Number(f.Size) || 0) / max * 100))}%"></i></div>
                <span class="afile-size">${esc(fmtSize(f.Size))}</span>
            </div>
        </div>`).join('')
        : `<div class="empty"><div class="empty-title">${esc(T.noItems || '')}</div></div>`;

    scroll.innerHTML = `<div class="hero">
        <div class="hero-label">${esc(T.largeFilesHeading || '')}</div>
        <div class="hero-value hero-sm">${esc(fmtSize(total))}</div>
        <div class="hero-sub">${esc(T.analyzeTotal || '')} ${lf.length} ${esc(T.itemSuffix || '')} · ${esc(T.largeFilesDescription || '')}</div>
    </div>
    <div class="card"><div style="padding:6px 18px">${rows}</div></div>`;

    $('analyzeFooter').innerHTML = `<div class="footer-summary"><span class="footer-note">${esc(T.scannedAt || '')} ${esc(fmtWhen(scanResult.CompletedAt))}</span></div>
        <button class="btn ghost" data-action="go-scan">${esc(T.refreshButton || '')}</button>`;
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
            <span class="when">${esc(fmtWhen(h.CompletedAt))}</span>
            <span class="freed">${esc(h.BytesFreedText || '0 B')}</span>
            <span class="rules">${esc(arr(h.SelectedRuleIds).map(ruleLabel).join('、'))}</span>
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
        <button class="btn ghost" data-action="open-recyclebin">${esc(T.openRecycleBin || '')}</button>
        <button class="btn ghost" data-action="open-logs">${esc(T.logsButton || '')}</button>`;

    if (receiptOpen) await renderReceipt(receiptOpen);
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
            [T.summaryProcessed, String(s.SuccessfulCount || 0), false],
            [T.summaryRecycled, s.BytesRecycledText || '0 B', false],
            [T.summaryFailed, String(s.FailedCount || 0), Number(s.FailedCount) > 0],
        ];
        detail = `<div class="kv">${kv.map(([k, v, d]) =>
            `<div><dt>${esc(k)}</dt><dd class="${d ? 'danger' : ''}">${esc(v)}</dd></div>`).join('')}</div>`;
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
            <span class="group-meta">${esc(fmtWhen(h.CompletedAt))} · ${esc(h.BytesFreedText || '0 B')}</span>
            <span class="group-tools"><button class="btn small ghost" data-action="close-receipt">${esc(T.closeButton || '')}</button></span>
        </div>
        <div style="padding:14px 18px">
            <div class="receipt-path">${esc(path || '')}</div>
            ${detail}
        </div>
    </div>`;
}

/* ---------------- 动作 ---------------- */

async function startScan() {
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
}

async function startClean() {
    if (!selected.size) return;
    const cats = selectedLive();
    const delBytes = cats.filter((c) => c.Action === 'delete').reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);
    const recBytes = cats.filter((c) => c.Action === 'recycle').reduce((s, c) => s + (Number(c.TotalSize) || 0), 0);

    const lines = [T.confirmQuestion || ''];
    if (delBytes) lines.push(`${T.confirmPermanent}：${fmtSize(delBytes)}（不可还原）`);
    if (recBytes) lines.push(`${T.confirmRecycle}：${fmtSize(recBytes)}（可在回收站还原，不立即释放空间）`);
    if (!confirm(lines.join('\n\n'))) return;

    scanState = 'cleaning';
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
    scanState = 'done';
    scanResult = null;            // 扫过的内容已经被处理，旧结果不再可信
    selected = new Set();
    historyRows = null;
    renderClean();
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
    cancel: async () => { await QDF.cancel(); scanState = 'idle'; renderClean(); },
    clean: () => startClean(),
    'group-all': (el) => setGroup(el.dataset.group, true),
    'group-none': (el) => setGroup(el.dataset.group, false),
    'toggle-detail': (el) => toggleDetail(el.closest('.rule')),
    'toggle-cat': (el) => { const b = el.closest('.cat-block'); if (b) b.classList.toggle('collapsed'); },
    'go-analyze': () => showTab('analyze'),
    'go-scan': () => { showTab('clean'); startScan(); },
    'open-recyclebin': () => QDF.openPath('recyclebin'),
    'open-logs': () => QDF.openPath('logs'),
    'open-receipt': (el) => renderReceipt(Number(el.dataset.idx)),
    'close-receipt': () => { receiptOpen = null; const b = $('receiptBox'); if (b) b.innerHTML = ''; },
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
    renderClean();
});

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
    QDF.on('clean:progress', () => {});
    QDF.on('clean:done', onCleanDone);
    QDF.on('app:error', (e) => showError(e && e.message ? e.message : String(e)));

    showTab('clean');
})();
