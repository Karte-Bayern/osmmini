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
const css=fs.readFileSync(require.resolve('../web/style.css'),'utf8');
const editorSource=fs.readFileSync(require.resolve('../web/osm-editor.js'),'utf8');
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]));
const dynamicIds=new Set([...editorSource.matchAll(/\bid:'(osm[A-Z][A-Za-z]*)'/g)].map(m=>m[1]));
const railViews=[...html.matchAll(/<button type="button" data-map-view="([a-z]+)" aria-pressed="(?:true|false)">(.*?)<\/button>/g)];
test('rail lists every view once with a visible label; maps and OSM editing are first-class views',()=>{
 assert.deepEqual(railViews.map(m=>m[1]),['explore','route','assistant','maps','edit','tools']);
 for(const [,view,inner] of railViews)assert.match(inner.replace(/<svg.*?<\/svg>/g,'').replace(/<[^>]+>/g,'').trim(),/^[A-Za-zÄÖÜäöü-]{4,}$/,view);
 assert.match(html,/data-sidebar-open="settings"/);assert.ok(!html.includes('data-sidebar-open="osm"'));
});
test('every view has content, and each panel section is declared for its views only',()=>{
 for(const [,view] of railViews){
  assert.ok(new RegExp(`data-view-only="[^"]*\\b${view}\\b[^"]*"`).test(html),`no section for ${view}`);
  assert.ok(css.includes(`.maps-shell[data-view="${view}"] [data-view-only]:not([data-view-only~="${view}"])`),`no hiding rule for ${view}`);
 }
 const only=id=>html.match(new RegExp(`id="${id}"[^>]*data-view-only="([^"]+)"|data-view-only="([^"]+)"[^>]*id="${id}"`)).slice(1).find(Boolean);
 assert.equal(only('osmEditView'),'edit');assert.equal(only('mapsView'),'maps');assert.equal(only('aiCard'),'assistant');
 for(const id of ['territoryCard','operationsCard','settingsCard','helpCard','mapPostTools'])assert.equal(only(id),'tools',id);
});
test('map sources live in the Karten view, not in the settings or tools',()=>{
 const maps=html.indexOf('id="mapsView"'),edit=html.indexOf('id="osmEditView"'),settings=html.indexOf('id="settingsCard"');
 for(const id of ['mapSection','tinyTilesSection','tileSourceCards','saveMapSettings']){const at=html.indexOf(`id="${id}"`);assert.ok(at>maps&&at<edit,id);}
 assert.ok(!html.slice(settings).includes('id="tileSourceCards"'));assert.ok(!html.includes('osmEditorTools'));
 assert.ok(!html.includes('sidebar-quick-action'));
});
test('editor ids used by the script exist and the tab pattern is wired both ways',()=>{
 const used=new Set([...editorSource.matchAll(/'(osm[A-Z][A-Za-z]*)'/g)].map(m=>m[1]));
 assert.ok(used.size>40);
 for(const id of used)assert.ok(ids.has(id)||dynamicIds.has(id)||id==='osmField',`missing #${id}`);
 for(const tab of ['Find','Edit','Drafts']){
  const button=html.match(new RegExp(`<button id="osmTab${tab}"[^>]*>`))[0];
  assert.match(button,/role="tab"/);const panel=button.match(/aria-controls="([^"]+)"/)[1];
  assert.match(html,new RegExp(`id="${panel}" role="tabpanel" aria-labelledby="osmTab${tab}"`));
 }
 assert.match(html,/id="osmEditorStatus"[^>]*role="status"[^>]*aria-live="polite"/);assert.match(html,/id="osmValidation" role="alert"/);
});
