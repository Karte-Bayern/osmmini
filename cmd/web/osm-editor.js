/* Versioned OSM tag drafts; no uploads or topology mutations. */
(function(root){
  'use strict';
  const validID=n=>Number.isSafeInteger(n)&&n>0;
  const xmlText=s=>![...s].some(c=>{const n=c.codePointAt(0);return !(n===9||n===10||n===13||(n>=32&&n<=0xD7FF)||(n>=0xE000&&n<=0xFFFD)||(n>=0x10000&&n<=0x10FFFF));});
  function tags(entries) {
    if(entries.length>200)throw Error('Maximal 200 Tags pro Objekt.');
    const out=Object.create(null);
    for(const [k,v] of entries){
      if(typeof k!=='string'||typeof v!=='string')throw Error('Tags müssen Text sein.');
      if(!k&&!v)continue;
      if(!k||[...k].length>255||[...v].length>255||!xmlText(k)||!xmlText(v))throw Error('Tags benötigen einen Schlüssel und gültigen Text mit maximal 255 Zeichen pro Feld.');
      if(Object.hasOwn(out,k))throw Error('Doppelter Tag-Schlüssel: '+k);
      out[k]=v;
    }
    return out;
  }
  function element(raw,create=false){
    if(!raw||!['node','way'].includes(raw.type)||!(create?raw.type==='node'&&Number.isSafeInteger(raw.id)&&raw.id<0:validID(raw.id)&&validID(raw.version))||raw.visible===false)throw Error('Objekt ohne gültige ID/Version oder nicht mehr sichtbar.');
    if(raw.tags!==undefined&&(!raw.tags||typeof raw.tags!=='object'||Array.isArray(raw.tags)))throw Error('Ungültige Tags.');
    const e={type:raw.type,id:raw.id,...(!create?{version:raw.version}:{}),tags:tags(Object.entries(raw.tags||{}))};
    if(e.type==='node'){
      if(!Number.isFinite(raw.lon)||!Number.isFinite(raw.lat)||Math.abs(raw.lon)>180||Math.abs(raw.lat)>90)throw Error('Ungültige Punktkoordinaten.');
      e.lon=raw.lon;e.lat=raw.lat;
    }else{
      if(!Array.isArray(raw.nodes)||raw.nodes.length<2||raw.nodes.length>2000||!raw.nodes.every(validID))throw Error('Unvollständige Wegreferenzen.');
      e.nodes=raw.nodes.slice();
    }
    return e;
  }
  function changes(before,after){
    return [...new Set([...Object.keys(before),...Object.keys(after)])].sort().filter(k=>before[k]!==after[k]).map(key=>({key,before:before[key],after:after[key]}));
  }
  function validateDraft(d){
    const base=d.base?element(d.base):null, value=element(d.value,!base);
    if(base&&(base.type!==value.type||base.id!==value.id||base.version!==value.version||base.lon!==value.lon||base.lat!==value.lat||JSON.stringify(base.nodes)!==JSON.stringify(value.nodes)))throw Error('Bestehende Geometrien und Versionen dürfen nicht verändert werden.');
    if(!base&&!Object.values(value.tags).some(v=>v.trim()))throw Error('Ein neuer Punkt benötigt mindestens einen Tag.');
    return {base,value};
  }
  const esc=s=>String(s).replace(/[&<>"'\n\r\t]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;','\n':'&#10;','\r':'&#13;','\t':'&#9;'}[c]));
  function osc(drafts){
    if(drafts.length>100)throw Error('Maximal 100 Entwürfe.');
    const seen=new Set(),groups={create:[],modify:[]};
    for(const raw of drafts){
      const {base,value:e}=validateDraft(raw),key=e.type+'/'+e.id;
      if(seen.has(key))throw Error('Objekt mehrfach vorhanden.');seen.add(key);
      if(base&&!changes(base.tags,e.tags).length)continue;
      const attrs=`id="${e.id}"${base?` version="${e.version}"`:''}${e.type==='node'?` lat="${e.lat}" lon="${e.lon}"`:''}`;
      const children=(e.nodes||[]).map(id=>`      <nd ref="${id}"/>`).concat(Object.keys(e.tags).sort().map(k=>`      <tag k="${esc(k)}" v="${esc(e.tags[k])}"/>`));
      groups[base?'modify':'create'].push(`    <${e.type} ${attrs}>\n${children.join('\n')}\n    </${e.type}>`);
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n<osmChange version="0.6" generator="OSMmini">\n'+Object.entries(groups).filter(([,es])=>es.length).map(([g,es])=>`  <${g}>\n${es.join('\n')}\n  </${g}>`).join('\n')+'\n</osmChange>\n';
  }
  function restore(raw){const d=JSON.parse(raw);if(d.version!==1||!Array.isArray(d.drafts)||d.drafts.length>100)throw Error('Ungültige Entwurfsdatei.');const drafts=d.drafts.map(validateDraft);osc(drafts);return drafts;}
  async function checkVersions(drafts, fetcher=fetch){
    const issues=[];
    for(const {base} of drafts){
      if(!base)continue;
      const response=await fetcher(`https://api.openstreetmap.org/api/0.6/${base.type}/${base.id}.json`,{signal:AbortSignal.timeout(15000),credentials:'omit'});
      if(response.status===404||response.status===410){issues.push(`${base.type}/${base.id}: nicht mehr verfügbar.`);continue;}
      if(!response.ok)throw Error(`Versionsprüfung fehlgeschlagen (HTTP ${response.status}).`);
      const body=await response.json(),live=element(body.elements?.find(e=>e.type===base.type&&e.id===base.id));
      if(live.version!==base.version)issues.push(`${base.type}/${base.id}: Basisversion ${base.version}, aktuell ${live.version}.`);
    }
    return issues;
  }
  function create(map,options={}){
    const el=id=>document.getElementById(id),status=el('osmEditorStatus'),key='osmmini.osm-drafts.v1';
    let drafts=[],current=null,dirty=false,active=false,busy=false;
    try{const raw=localStorage.getItem(key);if(raw)drafts=restore(raw);}catch{status.textContent='Gespeicherte Entwürfe konnten nicht geladen werden.';}
    let undo=[],redo=[],saved=JSON.stringify(drafts),checkedFor='',conflicts=[];
    const versions=()=>JSON.stringify(drafts.filter(d=>d.base).map(d=>[d.base.type,d.base.id,d.base.version]).sort());
    const label=e=>`${e.type}/${e.id}${e.version?' · Version '+e.version:' · neuer Punkt'}`;
    function persist(record=true){const next=JSON.stringify(drafts);if(record&&next!==saved){undo.push(saved);if(undo.length>30)undo.shift();redo=[];}saved=next;try{localStorage.setItem(key,JSON.stringify({version:1,drafts}));return '';}catch{return ' Lokale Speicherung fehlgeschlagen; bitte exportieren.';}}
    function readTags(){return tags([...el('osmTags').children].map(row=>[row.children[0].value,row.children[1].value]));}
    function diff(){
      const list=el('osmDiff');list.replaceChildren();if(!current)return;
      try{for(const d of changes(current.base?.tags||{},readTags())){const li=document.createElement('li');li.textContent=`${d.key}: ${d.before===undefined?'(neu)':JSON.stringify(d.before)} → ${d.after===undefined?'(entfernt)':JSON.stringify(d.after)}`;list.append(li);}}catch(e){const li=document.createElement('li');li.textContent=e.message;list.append(li);}
    }
    function row(k='',v=''){
      const div=document.createElement('div'),input=document.createElement('input'),value=document.createElement('textarea'),remove=document.createElement('button');
      div.className='osm-tag-row';input.value=k;input.placeholder='Schlüssel';input.setAttribute('aria-label','Tag-Schlüssel');value.value=v;value.rows=1;value.placeholder='Wert';value.setAttribute('aria-label','Tag-Wert');
      remove.type='button';remove.textContent='×';remove.setAttribute('aria-label','Tag entfernen');remove.addEventListener('click',()=>{div.remove();dirty=true;diff();});
      div.append(input,value,remove);el('osmTags').append(div);
    }
    function open(d){current=structuredClone(d);dirty=false;el('osmForm').hidden=false;el('osmSelected').textContent=label(d.value);el('osmTags').replaceChildren();Object.entries(d.value.tags).forEach(([k,v])=>row(k,v));diff();}
    function canSwitch(){if(dirty){status.textContent='Offene Tag-Änderungen erst übernehmen oder verwerfen.';return false;}return !busy;}
    function render(){
      if(!map.isStyleLoaded())return;
      const data={type:'FeatureCollection',features:drafts.filter(d=>d.value.type==='node').map(({value:e})=>({type:'Feature',properties:{},geometry:{type:'Point',coordinates:[e.lon,e.lat]}}))};
      if(map.getSource('osm-drafts'))map.getSource('osm-drafts').setData(data);else{map.addSource('osm-drafts',{type:'geojson',data});map.addLayer({id:'osm-drafts-points',type:'circle',source:'osm-drafts',paint:{'circle-radius':7,'circle-color':'#8b5cf6','circle-stroke-width':2,'circle-stroke-color':'#fff'}});}
      options.onChange?.();
    }
    function refresh(){
      el('osmUndo').disabled=!undo.length;el('osmRedo').disabled=!redo.length;
      el('osmDrafts').replaceChildren();el('osmExport').disabled=!drafts.length;el('osmBackup').disabled=!drafts.length;
      drafts.forEach((d,i)=>{const li=document.createElement('li'),edit=document.createElement('button'),remove=document.createElement('button');edit.type=remove.type='button';edit.className=remove.className='btn btn-ghost';edit.textContent=label(d.value);edit.addEventListener('click',()=>{if(canSwitch()){cancel();open(d);if(d.value.type==='node')map.flyTo({center:[d.value.lon,d.value.lat],zoom:18});}});remove.textContent='Entwurf entfernen';remove.addEventListener('click',()=>{if(!canSwitch())return;drafts.splice(i,1);if(current?.value.id===d.value.id&&current?.value.type===d.value.type){current=null;el('osmForm').hidden=true;}status.textContent='Entwurf entfernt.'+persist();refresh();});li.append(edit,remove);el('osmDrafts').append(li);});render();
    }
    function cancel(){active=false;map.getCanvas().style.cursor='';el('osmNew').setAttribute('aria-pressed','false');}
    async function load(type,id){
      if(!canSwitch())return;
      if(!['node','way'].includes(type)||!validID(Number(id))){status.textContent='Eine positive OSM-ID eingeben.';return;}
      const saved=drafts.find(d=>d.value.type===type&&d.value.id===Number(id));
      if(saved){cancel();open(saved);status.textContent='Vorhandenen Entwurf geöffnet; Basisversion bleibt erhalten.';return;}
      cancel();busy=true;status.textContent='Aktuellen Objektstand von api.openstreetmap.org laden …';
      try{
        const response=await fetch(`https://api.openstreetmap.org/api/0.6/${type}/${id}.json`,{signal:AbortSignal.timeout(15000),credentials:'omit'});
        if(!response.ok)throw Error(`OSM-Objekt konnte nicht geladen werden (HTTP ${response.status}).`);
        const body=await response.json(),base=element(body.elements?.find(e=>e.type===type&&e.id===Number(id)));
        if(dirty)throw Error('Offene Tag-Änderungen erst übernehmen oder verwerfen, dann erneut laden.');
        open({base,value:structuredClone(base)});if(base.type==='node')map.flyTo({center:[base.lon,base.lat],zoom:18});status.textContent='Aktueller Stand geladen. Tags bearbeiten und als Entwurf übernehmen.';
      }catch(e){status.textContent=e.message;}finally{busy=false;}
    }
    el('osmLoad').addEventListener('click',()=>load(el('osmType').value,el('osmID').value));
    el('osmNearby').addEventListener('click',async()=>{
      if(busy)return;busy=true;status.textContent='Lokale Objekte im Umkreis von 500 m suchen …';
      try{const p=map.getCenter(),params=new URLSearchParams({lat:p.lat,lon:((p.lng+180)%360+360)%360-180,radius_m:500,limit:50});const response=await fetch('/api/v1/geo/pois?'+params,{signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Lokale Suche fehlgeschlagen.');const body=await response.json();el('osmCandidates').replaceChildren();for(const f of body.features){const type=f.properties.kind==='node'?'node':'way',id=f.properties.osm_id,li=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='btn btn-ghost';button.textContent=`${f.properties.label} · ${type}/${id} von OSM laden`;button.addEventListener('click',()=>load(type,id));li.append(button);el('osmCandidates').append(li);}status.textContent=`${body.features.length} lokale Objekte (maximal 50). Auswahl lädt den aktuellen Stand von OSM.`;}catch(e){status.textContent=e.message;}finally{busy=false;}
    });
    el('osmNew').addEventListener('click',()=>{if(!canSwitch())return;if(active){cancel();status.textContent='Punktsetzen beendet.';return;}options.onStart?.();active=true;el('osmNew').setAttribute('aria-pressed','true');map.getCanvas().style.cursor='crosshair';status.textContent='Neuen Punkt auf der Karte setzen. Esc bricht ab.';});
    el('osmAddTag').addEventListener('click',()=>{row();dirty=true;});
    el('osmTags').addEventListener('input',()=>{dirty=true;diff();});
    el('osmDiscard').addEventListener('click',()=>{current=null;dirty=false;el('osmForm').hidden=true;status.textContent='Offene Bearbeitung verworfen; gespeicherte Entwürfe bleiben erhalten.';});
    el('osmSave').addEventListener('click',()=>{
      try{if(!current)return;const d=validateDraft({...current,value:{...current.value,tags:readTags()}});const index=drafts.findIndex(x=>x.value.id===d.value.id&&x.value.type===d.value.type);
        if(!d.base&&!Object.keys(d.value.tags).length)throw Error('Ein neuer Punkt benötigt mindestens einen Tag.');
        if(d.base&&!changes(d.base.tags,d.value.tags).length){if(index>=0)drafts.splice(index,1);status.textContent='Keine Tag-Änderungen; Objekt nicht im Export.';}
        else{if(index<0){if(drafts.length>=100)throw Error('Maximal 100 Entwürfe.');drafts.push(d);}else drafts[index]=d;status.textContent='Entwurf übernommen. Noch nicht auf OSM veröffentlicht.';}
        dirty=false;current=null;el('osmForm').hidden=true;status.textContent+=persist();refresh();
      }catch(e){status.textContent=e.message;}
    });
    function download(content,name,type){const url=URL.createObjectURL(new Blob([content],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
    el('osmExport').addEventListener('click',()=>{try{if(busy)throw Error('Laufenden Vorgang zuerst abschließen lassen.');if(checkedFor===versions()&&conflicts.length)throw Error('Versionskonflikte: Entwurf sichern und in einem OSM-Editor abgleichen.');if(dirty)throw Error('Offene Änderungen erst übernehmen oder verwerfen.');download(osc(drafts),'osm-entwurf.osc','application/xml');status.textContent='Änderungsdatei exportiert. Vor einem Upload Basisversionen und Änderungen in einem OSM-Editor prüfen.';}catch(e){status.textContent=e.message;}});
    el('osmBackup').addEventListener('click',()=>{if(dirty){status.textContent='Offene Änderungen erst übernehmen oder verwerfen.';return;}download(JSON.stringify({version:1,drafts},null,2),'osm-entwurf.json','application/json');});
    for(const id of ['osmUndo','osmRedo']) {
      // Resolve stacks dynamically because a new edit discards redo history.
      el(id).addEventListener('click',()=>{if(!canSwitch())return;const source=id==='osmUndo'?undo:redo,target=id==='osmUndo'?redo:undo;if(!source.length)return;target.push(JSON.stringify(drafts));drafts=JSON.parse(source.pop());current=null;el('osmForm').hidden=true;status.textContent='Entwurfsänderung '+(id==='osmUndo'?'rückgängig gemacht.':'wiederhergestellt.')+persist(false);refresh();});
    }
    el('osmCheck').addEventListener('click',async()=>{
      if(!canSwitch())return;busy=true;const snapshot=JSON.stringify(drafts);status.textContent='Basisversionen mit OSM abgleichen …';
      try{const found=await checkVersions(JSON.parse(snapshot));if(snapshot!==JSON.stringify(drafts))throw Error('Entwürfe wurden geändert; Versionsprüfung wiederholen.');checkedFor=versions();conflicts=found;status.textContent=found.length?'Versionskonflikte: '+found.join(' ')+' Bitte in einem OSM-Editor abgleichen.':drafts.some(d=>d.base)?'Alle Basisversionen sind aktuell. Vor einem späteren Upload erneut prüfen.':'Nur neue Punkte: keine Basisversionen zu prüfen. Duplikate bitte manuell prüfen.';}catch(e){status.textContent=e.message;}finally{busy=false;}
    });
    el('osmImport').addEventListener('change',async()=>{
      const file=el('osmImport').files[0];if(!file)return;
      if(!canSwitch()){el('osmImport').value='';return;}
      try{if(file.size>5*1024*1024)throw Error('Datei größer als 5 MB.');busy=true;const incoming=restore(await file.text()),merged=[...drafts,...incoming];if(dirty)throw Error('Offene Änderungen zuerst übernehmen oder verwerfen.');osc(merged);drafts=merged;status.textContent='Entwürfe ergänzt.'+persist();refresh();}catch(e){status.textContent=e.message;}finally{busy=false;el('osmImport').value='';}
    });
    document.addEventListener('keydown',e=>{if(e.key==='Escape'&&active){cancel();status.textContent='Punktsetzen beendet.';}});
    refresh();return {get active(){return active;},cancel,render,addPoint(event){if(!active||event.originalEvent?.target?.closest?.('.maplibregl-marker, .maplibregl-popup'))return;const id=Math.min(0,...drafts.map(d=>d.value.id))-1;try{const value=element({type:'node',id,lat:event.lngLat.lat,lon:((event.lngLat.lng+180)%360+360)%360-180,tags:{}},true);cancel();open({base:null,value});dirty=true;row('name','');status.textContent='Neuer Punkt gesetzt. Tags ergänzen und übernehmen.';}catch(e){status.textContent=e.message;}}};
  }
  root.OSMEditor={tags,element,changes,validateDraft,osc,restore,checkVersions,create};
})(typeof window==='undefined'?globalThis:window);
