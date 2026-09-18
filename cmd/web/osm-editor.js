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
    const fieldNames=Object.assign(Object.create(null),{name:'Name',website:'Website',opening_hours:'Öffnungszeiten',amenity:'Art des Ortes'});
    const kinds=Object.assign(Object.create(null),{bench:'Sitzbank',drinking_water:'Trinkwasserstelle',bicycle_parking:'Fahrradparkplatz',cafe:'Café'});
    const label=e=>e.tags.name||kinds[e.tags.amenity]||(e.type==='node'?'Unbenannter Ort':'Unbenannter Weg / Fläche');
    const common={osmName:'name',osmWebsite:'website',osmHours:'opening_hours'};
    let validForm=false;
    function syncCommon(){for(const [id,key] of Object.entries(common)){const row=[...el('osmTags').children].find(r=>r.children[0].value===key);el(id).value=row?.children[1].value||'';}}
    function syncUI(){
      el('osmFormFields').disabled=busy;
      el('osmEditorTools').setAttribute('aria-busy',String(busy));
      for(const id of ['osmNearby','osmNew','osmLoad','osmImport'])el(id).disabled=busy;
      el('osmNearby').textContent=busy?'Bitte warten …':'Orte in der Nähe finden';
      el('osmNew').textContent=active?'Punktsetzen abbrechen':'Neuen Ort eintragen';
      el('osmPlacement').hidden=!active;
      el('osmSave').disabled=busy||!current||!validForm;
      el('osmDiscard').textContent=dirty?'Ungespeicherte Änderungen verwerfen':'Bearbeitung schließen';
      el('osmEditState').textContent=dirty?'Noch nicht gespeichert – Änderungen lokal speichern.':'Keine ungespeicherten Änderungen.';
      el('osmUndo').disabled=busy||dirty||!undo.length;
      el('osmRedo').disabled=busy||dirty||!redo.length;
      el('osmCheck').disabled=busy||dirty||!drafts.some(d=>d.base);
      for(const id of ['osmExport','osmBackup'])el(id).disabled=busy||dirty||!drafts.length;
      el('osmDraftSummary').textContent=drafts.length?`${drafts.length} ${drafts.length===1?'Entwurf':'Entwürfe'} im Arbeitsstand.${dirty?' Offene Änderungen zuerst speichern oder verwerfen.':''}`:'Noch keine gespeicherten Entwürfe. Wähle einen Ort aus oder trage einen neuen ein.';
      el('osmCheckState').textContent=!drafts.length?'':checkedFor===versions()&&conflicts.length?'OSM wurde inzwischen geändert. Sichere den Arbeitsstand und löse die Konflikte in einem OSM-Editor.':!drafts.some(d=>d.base)?'Nur neue Orte. Bitte vor Veröffentlichung prüfen, ob sie bereits in OSM existieren.':checkedFor===versions()?'Beim letzten Vergleich waren die OSM-Versionen aktuell. Vor Veröffentlichung erneut prüfen.':'Noch nicht mit dem aktuellen OSM-Stand verglichen. Internetverbindung erforderlich.';
      if(checkedFor===versions()&&conflicts.length)el('osmExport').disabled=true;
    }
    function setBusy(value){if(value&&active)cancel();busy=value;syncUI();}
    function userError(error){if(error.name==='TimeoutError')return 'Die Antwort dauert zu lange. Bitte erneut versuchen.';if(error.name==='TypeError')return 'Verbindung fehlgeschlagen. Prüfe deine Internetverbindung und versuche es erneut.';if(error.name==='SyntaxError')return 'Die Datei oder Antwort konnte nicht gelesen werden. Verwende eine hier erstellte JSON-Sicherung oder lade den Ort erneut.';return error.message;}

    function persist(record=true){const next=JSON.stringify(drafts);if(record&&next!==saved){undo.push(saved);if(undo.length>30)undo.shift();redo=[];}saved=next;try{localStorage.setItem(key,JSON.stringify({version:1,drafts}));return '';}catch{return ' Lokale Speicherung fehlgeschlagen; bitte exportieren.';}}
    function readTags(){return tags([...el('osmTags').children].map(row=>[row.children[0].value,row.children[1].value]));}
    function diff(){
      const list=el('osmDiff');list.replaceChildren();validForm=false;
      el('osmValidation').textContent='';
      if(current){try{
        const next=readTags(),delta=changes(current.base?.tags||{},next);
        el('osmSelected').textContent=label({...current.value,tags:next});
        for(const d of delta){const li=document.createElement('li');li.textContent=`${fieldNames[d.key]||d.key}: ${d.before===undefined?'neu':JSON.stringify(d.before)} → ${d.after===undefined?'wird entfernt':JSON.stringify(d.after)}`;list.append(li);}
        if(!delta.length){const li=document.createElement('li');li.textContent='Noch keine Angaben geändert.';list.append(li);}
        if(!current.base&&!Object.values(next).some(v=>v.trim()))el('osmValidation').textContent='Wähle eine Art aus oder ergänze eine Eigenschaft für den neuen Ort.';
        else validForm=!!delta.length||drafts.some(d=>d.value.id===current.value.id&&d.value.type===current.value.type);
      }catch(e){el('osmValidation').textContent=e.message;}}
      syncUI();
    }
    function row(k='',v=''){
      const div=document.createElement('div'),input=document.createElement('input'),value=document.createElement('textarea'),remove=document.createElement('button');
      div.className='osm-tag-row';input.value=k;input.placeholder='Schlüssel';input.setAttribute('aria-label','OSM-Schlüssel');value.value=v;value.rows=1;value.placeholder='Wert';value.setAttribute('aria-label',(fieldNames[k]||k||'Eigenschaft')+' – Wert');
      remove.type='button';remove.textContent='×';remove.setAttribute('aria-label',(fieldNames[k]||k||'Eigenschaft')+' entfernen');remove.addEventListener('click',()=>{div.remove();dirty=true;syncCommon();diff();});
      div.append(input,value,remove);el('osmTags').append(div);
    }
    function open(d){current=structuredClone(d);dirty=false;el('osmForm').hidden=false;el('osmSelected').textContent=label(d.value);el('osmObjectMeta').textContent=d.base?`${d.value.type==='node'?'Punkt':'Weg / Fläche'} · OSM-ID ${d.value.id} · Version ${d.value.version}`:`Neuer Ort · ${d.value.lat.toFixed(5)}, ${d.value.lon.toFixed(5)}`;el('osmPresetWrap').hidden=!!d.base;el('osmPreset').value=Object.hasOwn(kinds,d.value.tags.amenity)?d.value.tags.amenity:'';el('osmTags').replaceChildren();Object.entries(d.value.tags).forEach(([k,v])=>row(k,v));syncCommon();diff();render();el('osmSelected').focus?.();}

    function canSwitch(){if(dirty){status.textContent='Du hast ungespeicherte Änderungen. Speichere sie in Schritt 2 oder verwirf sie dort.';el('osmSelected').focus?.();return false;}return !busy;}
    function render(){
      if(!map.isStyleLoaded())return;
      const shown=drafts.filter(d=>!current||d.value.id!==current.value.id||d.value.type!==current.value.type);if(current)shown.push(current);
      const data={type:'FeatureCollection',features:shown.filter(d=>d.value.type==='node').map(({value:e})=>({type:'Feature',properties:{selected:current?.value.id===e.id&&current?.value.type===e.type},geometry:{type:'Point',coordinates:[e.lon,e.lat]}}))};
      if(map.getSource('osm-drafts'))map.getSource('osm-drafts').setData(data);else{map.addSource('osm-drafts',{type:'geojson',data});map.addLayer({id:'osm-drafts-points',type:'circle',source:'osm-drafts',paint:{'circle-radius':['case',['get','selected'],10,7],'circle-color':['case',['get','selected'],'#2563eb','#8b5cf6'],'circle-stroke-width':2,'circle-stroke-color':'#fff'}});}
      options.onChange?.();
    }
    function refresh(){
      syncUI();
      el('osmDrafts').replaceChildren();
      drafts.forEach((d,i)=>{const li=document.createElement('li'),edit=document.createElement('button'),remove=document.createElement('button');edit.type=remove.type='button';edit.className=remove.className='btn btn-ghost';edit.textContent=label(d.value)+(d.base?' · bearbeitet':' · neu');edit.setAttribute('aria-label',label(d.value)+' bearbeiten');edit.addEventListener('click',()=>{if(canSwitch()){cancel();open(d);if(d.value.type==='node')map.flyTo({center:[d.value.lon,d.value.lat],zoom:18});}});remove.textContent='Entfernen';remove.setAttribute('aria-label',label(d.value)+' aus dem Arbeitsstand entfernen');remove.addEventListener('click',()=>{if(!canSwitch())return;drafts.splice(i,1);if(current?.value.id===d.value.id&&current?.value.type===d.value.type){current=null;el('osmForm').hidden=true;}status.textContent='Entwurf entfernt. Mit „Rückgängig“ wiederherstellen.'+persist();refresh();});li.append(edit,remove);el('osmDrafts').append(li);});render();
    }
    function cancel(){active=false;map.getCanvas().style.cursor='';el('osmNew').setAttribute('aria-pressed','false');syncUI();}
    async function load(type,id){
      if(!canSwitch())return;
      if(!['node','way'].includes(type)||!validID(Number(id))){status.textContent='Gib die numerische OSM-ID ein, zum Beispiel 123456. Du findest sie auf der Objektseite von OpenStreetMap.';return;}
      const saved=drafts.find(d=>d.value.type===type&&d.value.id===Number(id));
      if(saved){cancel();open(saved);status.textContent='Vorhandenen Entwurf geöffnet; Basisversion bleibt erhalten.';return;}
      id=String(Number(id));
      cancel();setBusy(true);status.textContent='Aktuellen Objektstand von api.openstreetmap.org laden …';
      try{
        const response=await fetch(`https://api.openstreetmap.org/api/0.6/${type}/${id}.json`,{signal:AbortSignal.timeout(15000),credentials:'omit'});
        if(!response.ok)throw Error(response.status===404||response.status===410?'Dieser Ort ist auf OSM nicht verfügbar. Prüfe die ID oder wähle einen anderen Ort.':response.status===429?'OSM erhält gerade zu viele Anfragen. Warte kurz und versuche es erneut.':`OSM konnte den Ort nicht laden (HTTP ${response.status}). Bitte erneut versuchen.`);
        const body=await response.json(),base=element(body.elements?.find(e=>e.type===type&&e.id===Number(id)));
        if(dirty)throw Error('Offene Tag-Änderungen erst übernehmen oder verwerfen, dann erneut laden.');
        open({base,value:structuredClone(base)});if(base.type==='node')map.flyTo({center:[base.lon,base.lat],zoom:18});status.textContent='Ort geladen. Bearbeite die Angaben in Schritt 2 und speichere sie lokal.';
      }catch(e){status.textContent=userError(e);}finally{setBusy(false);}
    }
    el('osmLoad').addEventListener('click',()=>load(el('osmType').value,el('osmID').value));
    el('osmNearby').addEventListener('click',async()=>{
      if(busy)return;setBusy(true);status.textContent='Lokale Objekte im Umkreis von 500 m suchen …';
      try{const p=map.getCenter(),params=new URLSearchParams({lat:p.lat,lon:((p.lng+180)%360+360)%360-180,radius_m:500,limit:50});const response=await fetch('/api/v1/geo/pois?'+params,{signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Lokale Suche fehlgeschlagen.');const body=await response.json();el('osmCandidates').replaceChildren();for(const f of body.features){const type=f.properties.kind==='node'?'node':'way',id=f.properties.osm_id,li=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='btn btn-ghost';button.textContent=`${f.properties.label} · bearbeiten`;button.setAttribute('aria-label',`${f.properties.label}, ${type==='node'?'Punkt':'Weg oder Fläche'} ${id}, bearbeiten`);button.addEventListener('click',()=>load(type,id));li.append(button);el('osmCandidates').append(li);}status.textContent=body.features.length?`${body.features.length} Orte gefunden. Wähle einen aus, um seine Angaben zu bearbeiten.`:'Keine Orte im lokalen Bestand gefunden. Verschiebe die Karte und suche erneut oder lade eine bekannte OSM-ID.';}catch(e){status.textContent=userError(e);}finally{setBusy(false);}
    });
    el('osmNew').addEventListener('click',()=>{if(!canSwitch())return;if(active){cancel();status.textContent='Punktsetzen beendet.';return;}options.onStart?.();active=true;el('osmNew').setAttribute('aria-pressed','true');map.getCanvas().style.cursor='crosshair';status.textContent='Klicke auf die genaue Position des neuen Ortes. Anschließend kannst du seine Angaben ergänzen.';syncUI();});
    el('osmAddTag').addEventListener('click',()=>{row();dirty=true;diff();el('osmTags').children[el('osmTags').children.length-1].children[0].focus?.();});
    el('osmTags').addEventListener('input',()=>{dirty=true;syncCommon();diff();});
    for(const [id,key] of Object.entries(common))el(id).addEventListener('input',()=>{
      const rows=[...el('osmTags').children].filter(r=>r.children[0].value===key),value=el(id).value;
      if(rows.length>1){status.textContent='Dieser Schlüssel ist mehrfach vorhanden. Bitte unter „Alle Eigenschaften“ korrigieren.';el('osmAdvancedTags').open=true;return;}
      if(rows.length){if(value)rows[0].children[1].value=value;else rows[0].remove();}else if(value)row(key,value);
      dirty=true;diff();
    });
    el('osmPreset').addEventListener('change',()=>{
      const kind=el('osmPreset').value;if(!current||current.base||!Object.hasOwn(kinds,kind)){status.textContent='Wähle zuerst eine Art für den neuen Ort.';return;}
      try{const next=readTags();next.amenity=kind;el('osmTags').replaceChildren();Object.entries(next).forEach(([k,v])=>row(k,v));dirty=true;syncCommon();diff();status.textContent=kinds[kind]+' gewählt. Ergänze nur Angaben, die du kennst, und speichere den Entwurf.';}catch(e){status.textContent=userError(e);}
    });
    el('osmDiscard').addEventListener('click',()=>{current=null;dirty=false;el('osmForm').hidden=true;status.textContent='Bearbeitung geschlossen. Bereits gespeicherte Entwürfe bleiben erhalten.';syncUI();render();el('osmNearby').focus?.();});
    el('osmSave').addEventListener('click',()=>{
      try{if(!current)return;const d=validateDraft({...current,value:{...current.value,tags:readTags()}});const index=drafts.findIndex(x=>x.value.id===d.value.id&&x.value.type===d.value.type);
        if(!d.base&&!Object.keys(d.value.tags).length)throw Error('Ein neuer Punkt benötigt mindestens einen Tag.');
        if(d.base&&!changes(d.base.tags,d.value.tags).length){if(index>=0)drafts.splice(index,1);status.textContent='Keine Tag-Änderungen; Objekt nicht im Export.';}
        else{if(index<0){if(drafts.length>=100)throw Error('Maximal 100 Entwürfe.');drafts.push(d);}else drafts[index]=d;status.textContent='Änderungen lokal gespeichert. In Schritt 3 kannst du sie prüfen und herunterladen.';}
        dirty=false;current=null;el('osmForm').hidden=true;status.textContent+=persist();refresh();
      }catch(e){status.textContent=userError(e);}finally{syncUI();}
    });
    function download(content,name,type){const url=URL.createObjectURL(new Blob([content],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
    el('osmExport').addEventListener('click',()=>{try{if(busy)throw Error('Laufenden Vorgang zuerst abschließen lassen.');if(checkedFor===versions()&&conflicts.length)throw Error('Versionskonflikte: Entwurf sichern und in einem OSM-Editor abgleichen.');if(dirty)throw Error('Offene Änderungen erst übernehmen oder verwerfen.');download(osc(drafts),'osm-entwurf.osc','application/xml');status.textContent='Änderungsdatei exportiert. Vor einem Upload Basisversionen und Änderungen in einem OSM-Editor prüfen.';}catch(e){status.textContent=userError(e);}});
    el('osmBackup').addEventListener('click',()=>{if(dirty){status.textContent='Offene Änderungen erst übernehmen oder verwerfen.';return;}download(JSON.stringify({version:1,drafts},null,2),'osm-entwurf.json','application/json');});
    for(const id of ['osmUndo','osmRedo']) {
      // Resolve stacks dynamically because a new edit discards redo history.
      el(id).addEventListener('click',()=>{if(!canSwitch())return;const source=id==='osmUndo'?undo:redo,target=id==='osmUndo'?redo:undo;if(!source.length)return;target.push(JSON.stringify(drafts));drafts=JSON.parse(source.pop());current=null;el('osmForm').hidden=true;status.textContent='Entwurfsänderung '+(id==='osmUndo'?'rückgängig gemacht.':'wiederhergestellt.')+persist(false);refresh();});
    }
    el('osmCheck').addEventListener('click',async()=>{
      if(!canSwitch())return;setBusy(true);const snapshot=JSON.stringify(drafts);status.textContent='Basisversionen mit OSM abgleichen …';
      try{const found=await checkVersions(JSON.parse(snapshot));if(snapshot!==JSON.stringify(drafts))throw Error('Entwürfe wurden geändert; Versionsprüfung wiederholen.');checkedFor=versions();conflicts=found;status.textContent=found.length?'Versionskonflikte: '+found.join(' ')+' Bitte in einem OSM-Editor abgleichen.':drafts.some(d=>d.base)?'Alle Basisversionen sind aktuell. Vor einem späteren Upload erneut prüfen.':'Nur neue Punkte: keine Basisversionen zu prüfen. Duplikate bitte manuell prüfen.';}catch(e){status.textContent=userError(e);}finally{setBusy(false);}
    });
    el('osmImport').addEventListener('change',async()=>{
      const file=el('osmImport').files[0];if(!file)return;
      if(!canSwitch()){el('osmImport').value='';return;}
      try{if(file.size>5*1024*1024)throw Error('Datei größer als 5 MB.');setBusy(true);const incoming=restore(await file.text()),merged=[...drafts,...incoming];if(dirty)throw Error('Offene Änderungen zuerst übernehmen oder verwerfen.');osc(merged);drafts=merged;status.textContent='Entwürfe ergänzt.'+persist();refresh();}catch(e){status.textContent=userError(e);}finally{setBusy(false);el('osmImport').value='';}
    });
    root.addEventListener?.('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
    document.addEventListener('keydown',e=>{if(e.key==='Escape'&&active){cancel();status.textContent='Punktsetzen beendet.';}});
    refresh();return {get active(){return active;},cancel,render,addPoint(event){if(!active||event.originalEvent?.target?.closest?.('.maplibregl-marker, .maplibregl-popup'))return;const id=Math.min(0,...drafts.map(d=>d.value.id))-1;try{const value=element({type:'node',id,lat:event.lngLat.lat,lon:((event.lngLat.lng+180)%360+360)%360-180,tags:{}},true);cancel();open({base:null,value});dirty=true;diff();status.textContent='Position gewählt. Wähle in Schritt 2 die Art des Ortes und ergänze seine Angaben.';el('osmPreset').focus?.();}catch(e){status.textContent=userError(e);}}};
  }
  root.OSMEditor={tags,element,changes,validateDraft,osc,restore,checkVersions,create};
})(typeof window==='undefined'?globalThis:window);
