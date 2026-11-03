const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../gui/frontend/app.js'), 'utf8').split('(async function init()')[0];
function context() {
    const elements = new Map();
    const element = id => {
        if (!elements.has(id)) elements.set(id, {textContent:'',innerHTML:'',classList:{add(){},remove(){}},addEventListener(){},setAttribute(){}});
        return elements.get(id);
    };
    // Timers and matchMedia are browser globals app.js relies on; the sandbox
    // must provide them or the module fails to evaluate.
    const ctx = vm.createContext({
        console, confirm:()=>true,
        setTimeout, clearTimeout, setInterval, clearInterval, requestAnimationFrame:(fn)=>fn(0),
        matchMedia:()=>({matches:false}),
        CSS:{escape:(s)=>s},
        document:{getElementById:element,querySelectorAll:()=>[],querySelector:()=>null,addEventListener(){}},
        QDF:{cancel:async()=>{},scan:async()=>{},clean:async()=>{}}
    });
    vm.runInContext(source,ctx);
    return ctx;
}
test('asynchronous cleanup failure resets stale state and allows retry',()=>{
    const ctx=context();
    vm.runInContext("scanState='cleaning';scanResult={Categories:[]};selected.add('cache');onTaskError({phase:'clean',message:'failed'});",ctx);
    assert.equal(vm.runInContext('scanState',ctx),'idle');
    assert.equal(vm.runInContext('scanResult',ctx),null);
    assert.equal(vm.runInContext('selected.size',ctx),0);
});
test('cancel waits for backend acknowledgement rather than reopening launch window',async()=>{
    const ctx=context();vm.runInContext("scanState='scanning'",ctx);
    await vm.runInContext('ACTIONS.cancel()',ctx);
    assert.equal(vm.runInContext('scanState',ctx),'scanning');
});
test('partial result is not presented without a warning',()=>{
    const ctx=context();
    vm.runInContext("scanState='cleaning';onCleanDone({type:'result',State:'Cancelled',SuccessfulCount:1});",ctx);
    assert.equal(vm.runInContext('scanState',ctx),'done');
    assert.match(vm.runInContext("$('errorMessage').textContent",ctx),/已停止/);
});
test('done screen lists every rule the backend reported',()=>{
    const ctx=context();
    // RuleResults drives the list; a rule that scanned nothing must say so
    // instead of looking like a rule that ran and found nothing.
    const html = vm.runInContext(`doneRuleList({RuleResults:[
        {RuleId:'a',RuleName:'更新缓存',Successful:1,Failed:0,Skipped:0,BytesFreed:5,Handled:true},
        {RuleId:'b',RuleName:'系统临时',Successful:0,Failed:0,Skipped:1,BytesFreed:2,Handled:true},
        {RuleId:'c',RuleName:'未安装项',Successful:0,Failed:0,Skipped:0,BytesFreed:0,Handled:false}
    ]})`,ctx);
    assert.match(html,/done-list/);
    assert.match(html,/更新缓存/);
    assert.match(html,/系统临时/);
    assert.match(html,/未安装项/);
    // three distinct states, not one generic label
    assert.match(html,/done-state ok/);
    assert.match(html,/done-state skip/);
    assert.match(html,/done-state none/);
    assert.match(html,/未发现目标/);
});
test('done screen shows nothing extra when the backend sent no RuleResults',()=>{
    const ctx=context();
    // Older receipts have no RuleResults; the list must stay absent rather
    // than rendering an empty card.
    const html = vm.runInContext('doneRuleList({RuleResults:[]})',ctx);
    assert.equal(html,'');
});
