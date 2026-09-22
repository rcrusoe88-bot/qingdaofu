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
    const ctx = vm.createContext({console, confirm:()=>true, document:{getElementById:element,querySelectorAll:()=>[],addEventListener(){}}, QDF:{cancel:async()=>{},scan:async()=>{},clean:async()=>{}}});
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
