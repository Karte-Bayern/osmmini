const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(require.resolve('../web/index.html'),'utf8');
const app=fs.readFileSync(require.resolve('../web/app.js'),'utf8');
test('decorative SVGs are hidden and nonfocusable; symbol references resolve',()=>{
 const svgs=html.match(/<svg\b[^>]*>/g);assert.ok(svgs.length>20);
 for(const svg of svgs){assert.match(svg,/aria-hidden="true"/);assert.match(svg,/focusable="false"/);}
 for(const [,id] of html.matchAll(/<use href="#([^"]+)"/g))assert.ok(html.includes(`id="${id}"`),id);
});
test('disclosure buttons have unique names, controlled content and one tab stop per header',()=>{
 for(const prefix of ['ai','territory','operations','settings','help']){
   const button=html.match(new RegExp(`<button id="${prefix}Toggle"[^>]*>`))[0];
   assert.match(button,/aria-label="[^"]+"/);assert.ok(button.includes(`aria-controls="${prefix}Body"`));assert.ok(html.includes(`id="${prefix}Body"`));
   const header=html.match(new RegExp(`<div[^>]*id="${prefix}CardHeader"[^>]*>`))[0];assert.ok(!header.includes('tabindex='));
 }
 for(const id of ['mapHeader','tinyTilesHeader','highwayHeader','speedHeader'])assert.match(html,new RegExp(`<button[^>]*id="${id}"[^>]*aria-controls="[^"]+"`));
});
test('card header forwarding does not intercept the native disclosure button keyboard',()=>{
 const source=app.slice(app.indexOf('function wireCollapsibleHeader('),app.indexOf('const operationsToggle ='));
 const handlers={},header={addEventListener:(event,fn)=>handlers[event]=fn};
 const icon={},button={contains:target=>target===icon};let calls=0;
 const context=vm.createContext({});vm.runInContext(source,context);context.wireCollapsibleHeader(header,button,()=>calls++);
 assert.equal(handlers.keydown,undefined);
 handlers.click({target:button});handlers.click({target:icon});assert.equal(calls,0);
 handlers.click({target:header});assert.equal(calls,1);
});
