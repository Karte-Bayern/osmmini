const {test}=require('node:test');const assert=require('node:assert/strict');require('../web/osm-presets.js');require('../web/osm-editor.js');const E=OSMEditor;
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

const near=(actual,expected)=>expected.forEach((v,i)=>assert.ok(Math.abs(actual[i]-v)<1e-9,`${actual} vs ${expected}`));
test('way outlines, click radius and distances are derived without touching the network',()=>{
 const shape=E.wayShape([{type:'node',id:1,lon:12,lat:48},{type:'node',id:2,lon:12.002,lat:48},{type:'node',id:3,lon:12.002,lat:48.001},{type:'node',id:4,lon:12,lat:48.001},{type:'way',id:9,nodes:[1,2,3,4,1]}],9);
 assert.equal(shape.closed,true);assert.deepEqual(shape.bounds,[[12,48],[12.002,48.001]]);near(shape.center,[12.001,48.0005]);
 assert.equal(E.wayShape([{type:'way',id:9,nodes:[1,2]}],9),null);
 assert.ok(E.pickRadiusMeters(48,10)>E.pickRadiusMeters(48,19));assert.equal(E.pickRadiusMeters(48,30),6);assert.equal(E.pickRadiusMeters(0,0),500);
 assert.equal(E.formatDistance(12.4),'12 m');assert.equal(E.formatDistance(1530),'1,5 km');assert.equal(E.formatDistance(undefined),'');
});
test('a stored map position survives backups but never reaches the export',()=>{
 const way={type:'way',id:33,version:9,nodes:[1,2,3],tags:{building:'yes'}};
 const draft={base:way,value:{...way,tags:{building:'house'}},center:[12.5,48.5]};
 assert.deepEqual(E.restore(JSON.stringify({version:1,drafts:[draft]}))[0].center,[12.5,48.5]);
 assert.equal(E.validateDraft({...draft,center:[500,0]}).center,undefined);
 assert.ok(!E.osc([draft]).includes('12.5'));
});

class Element{
 constructor(tag='div'){
  const classes=new Set();
  Object.assign(this,{tag,children:[],value:'',listeners:{},attrs:{},hidden:false,disabled:false,className:'',textContent:'',innerHTML:'',style:{}});
  this.classList={add:c=>classes.add(c),remove:c=>classes.delete(c),contains:c=>classes.has(c),toggle:(c,on)=>{(on===undefined?!classes.has(c):on)?classes.add(c):classes.delete(c);}};
 }
 append(...es){for(const e of es){e.parent=this;this.children.push(e);}}
 replaceChildren(...es){this.children=[];this.append(...es);}
 remove(){if(this.parent)this.parent.children=this.parent.children.filter(e=>e!==this);}
 addEventListener(e,f){this.listeners[e]=f;}
 setAttribute(k,v){this.attrs[k]=String(v);}getAttribute(k){return this.attrs[k];}removeAttribute(k){delete this.attrs[k];}
 focus(){this.focused=true;}
 click(){if(!this.disabled)return this.listeners.click?.({preventDefault(){}});}
}
const walk=(node,found=[])=>{found.push(node);node.children.forEach(child=>walk(child,found));return found;};
const cafe={type:'node',id:42,version:3,lat:48,lon:12,tags:{name:'Alt',amenity:'cafe',website:'https://alt.example'}};
const poi=(id,label,category,distance,kind='node')=>({type:'Feature',properties:{osm_id:id,kind,label,category,distance_m:distance},geometry:{type:'Point',coordinates:[12,48]}});

function harness(initial=[],routes={}){
 const es=new Proxy({},{get:(target,id)=>target[id]??=new Element()}),keydowns=[],requests=[];
 global.document={getElementById:id=>es[id],createElement:tag=>new Element(tag),addEventListener:(type,f)=>{if(type==='keydown')keydowns.push(f);}};
 let stored=JSON.stringify({version:1,drafts:initial});
 global.localStorage={getItem:()=>stored,setItem:(_,v)=>stored=v};
 const sources={},layers={},canvas={style:{}};
 const map={sources,layers,canvas,isStyleLoaded:()=>true,getSource:id=>sources[id]?{setData:d=>sources[id].data=d}:null,addSource:(id,s)=>sources[id]={data:s.data},addLayer:l=>layers[l.id]=l,getLayer:id=>layers[id],getCanvas:()=>canvas,flyTo(o){this.flown=o;},fitBounds(b,o){this.fitted=[b,o];},getZoom:()=>17,getCenter:()=>({lng:12,lat:48})};
 const originalFetch=global.fetch;
 global.fetch=async url=>{
  requests.push(String(url));
  const route=Object.entries(routes).find(([part])=>String(url).includes(part));
  if(!route)return {ok:true,json:async()=>({features:[]})};
  const value=typeof route[1]==='function'?route[1](String(url)):route[1];
  return {ok:value.ok??true,status:value.status??200,json:async()=>value.body};
 };
 const editor=E.create(map);
 const field=key=>walk(es.osmFields).find(n=>n.attrs?.['data-key']===key);
 return {es,map,editor,requests,keydowns,restore:()=>{global.fetch=originalFetch;},
  drafts:()=>E.restore(stored),data:id=>sources[id]?.data,field,
  control:key=>field(key).children.find(n=>n.tag==='input'||n.className==='osm-choice'),
  type(key,value){const input=this.control(key);input.value=value;input.listeners.input();},
  preset:label=>walk(es.osmPresetChips).find(n=>n.tag==='button'&&n.children.some(c=>c.textContent===label))?.click(),
  rows:()=>es.osmTags.children.map(row=>[row.children[0].value,row.children[1].value]),
 };
}
const withHarness=(initial,routes,fn)=>async()=>{const h=harness(initial,routes);try{await fn(h);}finally{h.restore();}};

test('a new place is placed on the map, typed, saved, undone and redone without changing OSM',withHarness([],{},async h=>{
 const e=h.es;
 e.osmNew.click();assert.equal(h.editor.active,true);assert.equal(h.map.canvas.style.cursor,'crosshair');assert.match(e.osmPickText.textContent,/neuen Ort/);assert.equal(e.osmEditView.attrs['data-mode'],'place');
 await h.editor.mapClick({lngLat:{lat:48,lng:12}});
 assert.equal(h.editor.active,false);assert.equal(h.editor.tab,'edit');assert.equal(e.osmForm.hidden,false);assert.equal(e.osmPanelEdit.hidden,false);assert.equal(e.osmPanelFind.hidden,true);
 assert.equal(h.data('osm-drafts').features.length,1);assert.equal(h.data('osm-drafts').features[0].properties.selected,true);
 h.preset('Sitzbank');h.type('seats','3');e.osmSave.click();
 const [draft]=h.drafts();assert.equal(draft.value.tags.amenity,'bench');assert.equal(draft.value.tags.seats,'3');assert.deepEqual(draft.center,[12,48]);
 assert.equal(h.editor.tab,'find');assert.equal(e.osmEditorStatus.focused,true);assert.equal(e.osmDraftCount.textContent,'1');assert.equal(e.osmDraftCount.hidden,false);
 assert.match(e.osmDrafts.children[0].children[0].children[1].children[0].textContent,/Sitzbank/);
 e.osmUndo.click();assert.equal(h.drafts().length,0);assert.equal(h.data('osm-drafts').features.length,0);assert.equal(e.osmDraftCount.hidden,true);
 e.osmRedo.click();assert.equal(h.drafts().length,1);assert.equal(h.data('osm-drafts').features.length,1);
}));

test('guided new-place flow keeps own properties, replaces the previous type and explains unsaved state',withHarness([],{},async h=>{
 const e=h.es;
 assert.match(e.osmDraftSummary.textContent,/Noch keine/);assert.equal(e.osmCheck.disabled,true);
 h.editor.startAt({lat:48,lng:12});
 assert.equal(e.osmSave.disabled,true);assert.match(e.osmValidation.textContent,/Art/);assert.equal(e.osmFields.hidden,true);
 e.osmAddTag.click();const custom=e.osmTags.children[0];custom.children[0].value='operator';custom.children[0].listeners.input();custom.children[1].value='Stadt';custom.children[1].listeners.input();
 h.preset('Bushaltestelle');assert.deepEqual(h.rows().sort(),[['highway','bus_stop'],['operator','Stadt']]);
 assert.equal(e.osmFields.hidden,false);assert.ok(h.field('shelter'));assert.equal(h.field('seats'),undefined);
 assert.match(e.osmEditState.textContent,/Nicht gespeichert/);assert.equal(e.osmSave.disabled,false);assert.match(e.osmDiscard.textContent,/verwerfen/);
 walk(e.osmPresetChips).find(n=>n.textContent==='Ändern').click();h.preset('Café');
 assert.deepEqual(h.rows().sort(),[['amenity','cafe'],['operator','Stadt']]);
 assert.equal(e.osmExport.disabled,true);e.osmSave.click();
 assert.equal(h.drafts()[0].value.tags.amenity,'cafe');assert.equal(h.drafts()[0].value.tags.highway,undefined);assert.equal(e.osmExport.disabled,false);assert.match(e.osmDraftSummary.textContent,/1 Entwurf/);
}));

test('friendly fields, choices and raw tags stay in sync, including deletions and duplicates',withHarness([],{'api.openstreetmap.org/api/0.6/node/42':{body:{elements:[cafe]}}},async h=>{
 const e=h.es;
 await h.editor.load('node',42);
 assert.equal(h.editor.tab,'edit');assert.equal(e.osmPresetWrap.hidden,true);assert.equal(h.control('name').value,'Alt');assert.match(e.osmObjectMeta.textContent,/Version 3/);assert.equal(e.osmOsmLink.href,'https://www.openstreetmap.org/node/42');
 h.type('name','');assert.ok(!h.rows().some(([k])=>k==='name'));assert.ok(e.osmDiff.children.some(li=>li.textContent.includes('wird entfernt')));
 assert.equal(h.field('name').classList.contains('is-changed'),true);
 const site=e.osmTags.children.find(row=>row.children[0].value==='website');site.children[1].value='https://neu.example';site.children[1].listeners.input();
 assert.equal(h.control('website').value,'https://neu.example');
 const [yes]=h.control('wheelchair').children;yes.click();assert.ok(h.rows().some(([k,v])=>k==='wheelchair'&&v==='yes'));assert.equal(yes.attrs['aria-pressed'],'true');
 yes.click();assert.ok(!h.rows().some(([k])=>k==='wheelchair'));
 e.osmAddTag.click();const last=e.osmTags.children.at(-1);last.children[0].value='amenity';last.children[0].listeners.input();last.children[1].value='bar';last.children[1].listeners.input();
 assert.match(e.osmValidation.textContent,/Doppelter/);assert.equal(e.osmSave.disabled,true);
 last.children[2].click();assert.equal(e.osmSave.disabled,false);e.osmSave.click();
 assert.equal(h.drafts()[0].value.tags.name,undefined);assert.equal(h.drafts()[0].value.tags.website,'https://neu.example');assert.equal(h.drafts()[0].base.tags.name,'Alt');
}));

test('values are trimmed and typed hints warn without blocking the save',withHarness([],{'node/42':{body:{elements:[cafe]}}},async h=>{
 await h.editor.load('node',42);
 h.type('website','example.org');assert.equal(h.field('website').children.at(-1).hidden,false);assert.match(h.field('website').children.at(-1).textContent,/https/);assert.equal(h.es.osmSave.disabled,false);
 h.type('name','  Neuer Name  ');h.es.osmSave.click();assert.equal(h.drafts()[0].value.tags.name,'Neuer Name');
}));

test('network loading disables conflicting controls and restores them after failure',async()=>{
 const h=harness(),e=h.es;let reject;
 global.fetch=()=>new Promise((_,r)=>reject=r);
 try{
   e.osmType.value='node';e.osmID.value='42';const request=e.osmLoad.click();
   assert.equal(e.osmNew.disabled,true);assert.equal(e.osmFormFields.disabled,true);assert.equal(e.osmFormFields.attrs['aria-busy'],'true');assert.equal(e.osmDiscard.disabled,true);assert.equal(h.editor.active,false);
   reject(Error('Offline'));await request;
   assert.equal(e.osmNew.disabled,false);assert.equal(e.osmFormFields.disabled,false);assert.equal(e.osmFormFields.attrs['aria-busy'],'false');assert.match(e.osmEditorStatus.textContent,/Offline/);
 }finally{h.restore();}
});

test('discarding an unsaved point clears its preview and returns focus to the search',withHarness([],{},async h=>{
 const e=h.es;e.osmNew.click();await h.editor.mapClick({lngLat:{lat:48,lng:12}});
 assert.equal(h.data('osm-drafts').features.length,1);e.osmDiscard.click();
 assert.equal(h.data('osm-drafts').features.length,0);assert.equal(e.osmForm.hidden,true);assert.equal(e.osmEmpty.hidden,false);assert.equal(h.editor.tab,'find');assert.equal(e.osmSearch.focused,true);
}));

test('validation names invalid fields, updates renamed tag labels and restores focus after removal',withHarness([],{},async h=>{
 const e=h.es;h.editor.startAt({lat:48,lng:12});h.preset('Café');
 h.type('name','x'.repeat(256));assert.equal(h.control('name').attrs['aria-invalid'],'true');
 const row=e.osmTags.children.find(r=>r.children[0].value==='name');assert.equal(row.children[1].attrs['aria-invalid'],'true');assert.equal(row.children[1].attrs['aria-describedby'],'osmValidation');
 h.type('name','Bank');assert.equal(h.control('name').attrs['aria-invalid'],'false');
 const amenity=e.osmTags.children.find(r=>r.children[0].value==='amenity');
 amenity.children[0].value='operator';amenity.children[0].listeners.input();assert.equal(amenity.children[2].attrs['aria-label'],'Betreiber entfernen');
 amenity.children[2].click();e.osmAddTag.click();
 assert.equal(e.osmTags.children.length,2);
 const last=e.osmTags.children.at(-1);last.children[2].click();assert.equal(e.osmTags.children[0].children[0].focused,true);
}));

test('a context action starts an OSM draft at the selected point without replacing unsaved edits',withHarness([],{},async h=>{
 h.editor.startAt({lat:48.12,lng:12.34});assert.equal(h.data('osm-drafts').features[0].geometry.coordinates[1],48.12);
 h.preset('Café');h.type('name','Mein Ort');h.editor.startAt({lat:49,lng:13});
 assert.equal(h.control('name').value,'Mein Ort');assert.equal(h.data('osm-drafts').features[0].geometry.coordinates[1],48.12);assert.match(h.es.osmEditorStatus.textContent,/ungespeichert/);
}));

test('clicking the map while the edit view is open picks the nearest recorded place',withHarness([],{'api/v1/geo/pois':{body:{features:[poi(42,'Alt','cafe',6)]}},'node/42':{body:{elements:[cafe]}}},async h=>{
 const e=h.es,timers=[],setTimeoutOriginal=global.setTimeout;global.setTimeout=fn=>timers.push(fn);
 try{h.editor.enter();}finally{global.setTimeout=setTimeoutOriginal;}
 assert.equal(h.editor.active,true);assert.equal(h.map.canvas.style.cursor,'pointer');assert.equal(e.osmPickHint.attrs['data-active'],'true');
 await h.editor.mapClick({lngLat:{lat:48,lng:12}});
 const poiRequest=h.requests.find(url=>url.includes('geo/pois'));assert.match(poiRequest,/radius_m=\d+/);assert.match(poiRequest,/limit=10/);
 assert.equal(h.editor.tab,'edit');assert.equal(e.osmSelected.textContent,'Alt');assert.equal(h.editor.active,false);
 e.osmDiscard.click();assert.equal(h.editor.active,true);
 h.editor.leave();assert.equal(h.editor.active,false);assert.equal(h.map.canvas.style.cursor,'');
}));

test('a click without a recorded place offers to add one there',withHarness([],{},async h=>{
 const e=h.es,setTimeoutOriginal=global.setTimeout;global.setTimeout=()=>0;
 try{h.editor.enter();}finally{global.setTimeout=setTimeoutOriginal;}
 await h.editor.mapClick({lngLat:{lat:48.5,lng:12.5}});
 assert.equal(e.osmPickMiss.hidden,false);assert.equal(h.editor.tab,'find');
 e.osmPickPlace.click();assert.equal(e.osmPickMiss.hidden,true);assert.equal(h.editor.tab,'edit');assert.equal(h.data('osm-drafts').features[0].geometry.coordinates[1],48.5);
}));

test('search lists places with category, distance and a name that describes the action',withHarness([],{'api/v1/geo/pois':{body:{features:[poi(42,'Café Alt','cafe',120),poi(7,'Bank','bench',2300,'way')]}},'node/42':{body:{elements:[cafe]}}},async h=>{
 const e=h.es;e.osmSearch.value='Bank';await e.osmSearchForm.listeners.submit({preventDefault(){}});
 assert.match(h.requests[0],/q=Bank/);assert.match(h.requests[0],/radius_m=5000/);
 assert.equal(e.osmCandidates.children.length,2);assert.equal(e.osmCandidatesEmpty.hidden,true);
 const [first,second]=e.osmCandidates.children.map(li=>li.children[0]);
 assert.match(first.attrs['aria-label'],/Café Alt, .*120 m, bearbeiten/);assert.match(second.attrs['aria-label'],/Sitzbank · Weg \/ Fläche · 2,3 km/);
 assert.equal(h.data('osm-candidates').features.length,2);
 first.listeners.mouseenter();assert.equal(h.data('osm-candidates').features[0].properties.active,true);
 await first.click();assert.equal(h.editor.tab,'edit');assert.equal(e.osmSelected.textContent,'Alt');assert.equal(h.data('osm-candidates').features.length,0);
}));

test('ways load their outline, keep a stored centre and never change geometry',withHarness([],{'way/9/full.json':{body:{elements:[{type:'node',id:1,lon:12,lat:48},{type:'node',id:2,lon:12.002,lat:48},{type:'node',id:3,lon:12.002,lat:48.001},{type:'node',id:4,lon:12,lat:48.001},{type:'way',id:9,version:2,nodes:[1,2,3,4,1],tags:{building:'yes'}}]}}},async h=>{
 const e=h.es;await h.editor.load('way',9);
 assert.match(h.requests.at(-1),/way\/9\/full\.json/);assert.equal(h.data('osm-selection').features[0].geometry.type,'Polygon');assert.ok(h.map.fitted);
 assert.equal(e.osmSelected.textContent,'Gebäude');assert.ok(h.field('name'));
 h.type('name','Rathaus');e.osmSave.click();
 const [draft]=h.drafts();near(draft.center,[12.001,48.0005]);assert.deepEqual(draft.value.nodes,[1,2,3,4,1]);assert.equal(h.data('osm-drafts').features[0].geometry.type,'Point');
 assert.equal(e.osmDrafts.children[0].children[1].disabled,false);
}));

test('tabs follow the keyboard pattern and control panels',withHarness([],{},async h=>{
 const e=h.es;
 assert.equal(e.osmTabFind.attrs['aria-selected'],'true');assert.equal(e.osmTabEdit.attrs.tabindex,'-1');assert.equal(e.osmPanelDrafts.hidden,true);
 let prevented=false;e.osmTabFind.listeners.keydown({key:'ArrowRight',preventDefault:()=>prevented=true});
 assert.equal(prevented,true);assert.equal(e.osmTabEdit.attrs['aria-selected'],'true');assert.equal(e.osmTabEdit.focused,true);assert.equal(e.osmPanelEdit.hidden,false);assert.equal(e.osmPanelFind.hidden,true);
 e.osmTabEdit.listeners.keydown({key:'End',preventDefault(){}});assert.equal(h.editor.tab,'drafts');
 e.osmTabDrafts.listeners.keydown({key:'ArrowRight',preventDefault(){}});assert.equal(h.editor.tab,'find');
}));

test('the save shortcut works only with an open, valid form',withHarness([],{},async h=>{
 const e=h.es,press=()=>{let prevented=false;h.keydowns.forEach(f=>f({key:'s',ctrlKey:true,preventDefault:()=>prevented=true}));return prevented;};
 assert.equal(press(),false);
 h.editor.startAt({lat:48,lng:12});assert.equal(press(),true);assert.equal(h.drafts().length,0);
 h.preset('Sitzbank');assert.equal(press(),true);assert.equal(h.drafts().length,1);assert.equal(h.editor.tab,'find');
}));

test('saving without differences removes a draft instead of exporting an empty change',withHarness([{base:cafe,value:{...cafe,tags:{...cafe.tags,name:'Neu'}}}],{},async h=>{
 const e=h.es;e.osmDrafts.children[0].children[0].click();assert.equal(h.control('name').value,'Neu');
 h.type('name','Alt');e.osmSave.click();assert.equal(h.drafts().length,0);assert.match(e.osmEditorStatus.textContent,/nicht im Export/);
}));

test('layers wait for a loading style and redraw once it is ready',async()=>{
 const h=harness(),timers=[],original=global.setTimeout;let loaded=false;
 const add=h.map.addSource;h.map.addSource=(id,source)=>{if(!loaded)throw Error('Style is not done loading');return add(id,source);};
 h.map.getLayer=id=>h.map.layers[id];
 for(const id of Object.keys(h.map.sources))delete h.map.sources[id];
 global.setTimeout=fn=>timers.push(fn);
 try{
  h.editor.startAt({lat:48,lng:12});
  assert.equal(h.data('osm-drafts'),undefined);assert.equal(timers.length,1);
  loaded=true;timers.shift()();
  assert.equal(h.data('osm-drafts').features.length,1);assert.ok(h.map.layers['osm-drafts-points']);assert.ok(h.map.layers['osm-candidates-points']);
  h.es.osmDiscard.click();assert.equal(h.data('osm-drafts').features.length,0);assert.equal(timers.length,0);
 }finally{global.setTimeout=original;}
 assert.equal(h.es.osmEditView.attrs['data-tab'],'find');
});
