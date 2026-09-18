const {test}=require('node:test');const assert=require('node:assert/strict');require('../web/osm-editor.js');const E=OSMEditor;
const base={type:'node',id:42,version:3,lat:48,lon:12,tags:{name:'Alt',amenity:'bench'}};
test('tag comparison covers additions changes removals and prototype-like keys',()=>{
 const t=E.tags([['name','Neu'],['__proto__','Wert']]);assert.equal(t.__proto__,'Wert');
 assert.deepEqual(E.changes(base.tags,t).map(d=>d.key),['__proto__','amenity','name']);
 for(const rows of [[['name','a'],['name','b']],[['','x']],[['name','\0']],[['name','x'.repeat(256)]]])assert.throws(()=>E.tags(rows));
 assert.equal(E.tags([['name','😀'.repeat(255)]]).name.length,510);
});
test('OSC preserves version geometry and way references and escapes XML',()=>{
 const way={type:'way',id:33,version:9,nodes:[1,2,3,1],tags:{building:'yes'}};
 const xml=E.osc([{base,value:{...base,tags:{name:'A & "B" <C>\nD'}}},{base:way,value:{...way,tags:{building:'house'}}},{base:null,value:{type:'node',id:-1,lat:49,lon:13,tags:{amenity:'bench'}}}]);
 assert.match(xml,/<modify>/);assert.match(xml,/<create>/);assert.match(xml,/id="42" version="3" lat="48" lon="12"/);assert.match(xml,/A &amp; &quot;B&quot; &lt;C&gt;&#10;D/);assert.equal((xml.match(/<nd ref=/g)||[]).length,4);assert.ok(!xml.includes('changeset='));
});
test('invalid versions geometry mutations and duplicate IDs are blocked',()=>{
 for(const value of [{...base,version:4},{...base,lat:49},{...base,type:'relation'},{...base,id:43},{...base,version:0}])assert.throws(()=>E.validateDraft({base,value}));
 const d={base,value:{...base,tags:{name:'Neu'}}};assert.throws(()=>E.osc([d,d]));
 assert.throws(()=>E.element({...base,id:Number.MAX_SAFE_INTEGER+1}));
 assert.throws(()=>E.element({type:'way',id:2,version:1,nodes:[],tags:{}}));
});
test('unchanged objects do not appear in OSC; backups validate on restore',()=>{
 assert.ok(!E.osc([{base,value:base}]).includes('<modify>'));
 const restored=E.restore(JSON.stringify({version:1,drafts:[{base,value:{...base,tags:{name:'Neu'}}}]}));assert.equal(restored[0].base.version,3);
 assert.throws(()=>E.restore(JSON.stringify({version:1,drafts:[{base,value:{...base,lon:13}}]})));
 assert.throws(()=>E.restore(JSON.stringify({version:2,drafts:[]})));
});
test('version check detects external edits and deleted objects without changing drafts',async()=>{
 const d={base,value:{...base,tags:{name:'Neu'}}},snapshot=JSON.stringify(d);
 assert.deepEqual(await E.checkVersions([d],async()=>({ok:true,json:async()=>({elements:[base]})})),[]);
 assert.match((await E.checkVersions([d],async()=>({ok:true,json:async()=>({elements:[{...base,version:4}]})})))[0],/aktuell 4/);
 assert.match((await E.checkVersions([d],async()=>({ok:false,status:410})))[0],/nicht mehr verfügbar/);
 await assert.rejects(E.checkVersions([d],async()=>({ok:false,status:429})),/429/);
 assert.equal(JSON.stringify(d),snapshot);
 assert.deepEqual(await E.checkVersions([{base:null,value:{...base,id:-1}}],()=>{throw Error('No network for creations');}),[]);
});
test('draft editor creates a point, saves, undoes and redoes without changing OSM',()=>{
 class Element{constructor(){this.children=[];this.value='';this.listeners={};}append(...es){this.children.push(...es);}replaceChildren(){this.children=[];}addEventListener(e,f){this.listeners[e]=f;}setAttribute(){}click(){return this.listeners.click?.();}}
 const es={};global.document={getElementById:id=>es[id]??=new Element(),createElement:()=>new Element(),addEventListener(){}};
 let stored=null,data=null;global.localStorage={getItem:()=>stored,setItem:(_,v)=>stored=v};
 const map={isStyleLoaded:()=>true,getSource:()=>data?{setData:d=>data=d}:null,addSource:(_,s)=>data=s.data,addLayer(){},getCanvas:()=>({style:{}})};
 const editor=E.create(map);es.osmNew.click();assert.equal(editor.active,true);editor.addPoint({lngLat:{lat:48,lng:12}});assert.equal(editor.active,false);
 es.osmName.value='Testbank';es.osmName.listeners.input();es.osmSave.click();assert.equal(E.restore(stored).length,1);assert.equal(data.features.length,1);
 es.osmUndo.click();assert.equal(E.restore(stored).length,0);assert.equal(data.features.length,0);
 es.osmRedo.click();assert.equal(E.restore(stored).length,1);assert.equal(data.features.length,1);
});

function editorHarness(initial=[]){
 class Element{
   constructor(){this.children=[];this.value='';this.listeners={};this.attrs={};}
   append(...es){for(const e of es){e.parent=this;this.children.push(e);}}
   replaceChildren(){this.children=[];}remove(){this.parent.children=this.parent.children.filter(e=>e!==this);}
   addEventListener(e,f){this.listeners[e]=f;}setAttribute(k,v){this.attrs[k]=v;}focus(){this.focused=true;}
   click(){if(!this.disabled)return this.listeners.click?.();}
 }
 const es={};global.document={getElementById:id=>es[id]??=new Element(),createElement:()=>new Element(),addEventListener(){}};
 let stored=JSON.stringify({version:1,drafts:initial}),data=null;
 global.localStorage={getItem:()=>stored,setItem:(_,v)=>stored=v};
 const map={isStyleLoaded:()=>true,getSource:()=>data?{setData:d=>data=d}:null,addSource:(_,s)=>data=s.data,addLayer(){},getCanvas:()=>({style:{}}),flyTo(){}};
 const editor=E.create(map);
 return {es,editor,drafts:()=>E.restore(stored),data:()=>data,input(id,value){es[id].value=value;es[id].listeners.input();}};
}
test('guided new-place flow applies a type, preserves properties and explains unsaved state',()=>{
 const h=editorHarness(),e=h.es;
 assert.match(e.osmDraftSummary.textContent,/Noch keine/);assert.equal(e.osmCheck.disabled,true);
 e.osmNew.click();assert.equal(e.osmPlacement.hidden,false);assert.match(e.osmNew.textContent,/abbrechen/);
 h.editor.addPoint({lngLat:{lat:48,lng:12}});assert.equal(h.data().features.length,1);assert.equal(h.data().features[0].properties.selected,true);
 assert.equal(e.osmSave.disabled,true);assert.match(e.osmValidation.textContent,/Art/);
 h.input('osmName','Am Brunnen');h.input('osmWebsite','https://example.org');
 e.osmPreset.value='bench';e.osmPreset.listeners.change();
 assert.equal(e.osmName.value,'Am Brunnen');assert.match(e.osmEditState.textContent,/Noch nicht gespeichert/);
 assert.equal(e.osmExport.disabled,true);assert.equal(e.osmSave.disabled,false);
 e.osmSave.click();assert.equal(h.drafts()[0].value.tags.amenity,'bench');assert.equal(h.drafts()[0].value.tags.website,'https://example.org');
 assert.equal(e.osmExport.disabled,false);assert.match(e.osmDraftSummary.textContent,/1 Entwurf/);
});
test('friendly fields and raw tags stay in sync, including deletions and validation errors',()=>{
 const h=editorHarness([{base,value:{...base,tags:{...base.tags,name:'Neu',operator:'Betreiber'}}}]),e=h.es;
 e.osmDrafts.children[0].children[0].click();assert.equal(e.osmName.value,'Neu');assert.equal(e.osmPresetWrap.hidden,true);
 h.input('osmName','');assert.ok(!e.osmTags.children.some(row=>row.children[0].value==='name'));
 assert.ok(e.osmDiff.children.some(li=>li.textContent.includes('wird entfernt')));
 const operator=e.osmTags.children.find(row=>row.children[0].value==='operator');assert.equal(operator.children[1].value,'Betreiber');
 e.osmAddTag.click();const last=e.osmTags.children.at(-1);last.children[0].value='amenity';last.children[1].value='cafe';e.osmTags.listeners.input();
 assert.match(e.osmValidation.textContent,/Doppelter/);assert.equal(e.osmSave.disabled,true);
 last.children[2].click();assert.equal(e.osmSave.disabled,false);e.osmSave.click();
 assert.equal(h.drafts()[0].value.tags.name,undefined);assert.equal(h.drafts()[0].value.tags.operator,'Betreiber');
});
test('network loading disables conflicting controls and restores them after failure',async()=>{
 const h=editorHarness(),e=h.es;let reject;
 const originalFetch=global.fetch;global.fetch=()=>new Promise((_,r)=>reject=r);
 try{
   document.getElementById('osmType').value='node';document.getElementById('osmID').value='42';const request=e.osmLoad.click();
   assert.equal(e.osmNew.disabled,true);assert.equal(e.osmFormFields.disabled,true);assert.equal(e.osmFormFields.attrs['aria-busy'],'true');
   reject(Error('Offline'));await request;
   assert.equal(e.osmNew.disabled,false);assert.equal(e.osmFormFields.disabled,false);assert.equal(e.osmFormFields.attrs['aria-busy'],'false');
 }finally{global.fetch=originalFetch;}
});
test('discarding an unsaved point clears its preview and returns focus to selection',()=>{
 const h=editorHarness(),e=h.es;e.osmNew.click();h.editor.addPoint({lngLat:{lat:48,lng:12}});
 assert.equal(h.data().features.length,1);e.osmDiscard.click();assert.equal(h.data().features.length,0);assert.equal(e.osmForm.hidden,true);assert.equal(e.osmNearby.focused,true);
});
test('validation names invalid fields, updates renamed tag labels and restores focus after removal',()=>{
 const h=editorHarness(),e=h.es;e.osmNew.click();h.editor.addPoint({lngLat:{lat:48,lng:12}});
 h.input('osmName','x'.repeat(256));assert.equal(e.osmName.attrs['aria-invalid'],'true');
 const row=e.osmTags.children[0];assert.equal(row.children[1].attrs['aria-invalid'],'true');assert.equal(row.children[1].attrs['aria-describedby'],'osmValidation');
 h.input('osmName','Bank');assert.equal(e.osmName.attrs['aria-invalid'],'false');
 row.children[0].value='operator';e.osmTags.listeners.input();assert.equal(row.children[2].attrs['aria-label'],'operator entfernen');
 row.children[2].click();assert.equal(e.osmAddTag.focused,true);
 h.input('osmName','Bank');e.osmSave.click();assert.equal(e.osmDraftSummary.focused,true);
});
