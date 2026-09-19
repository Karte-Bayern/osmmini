/* Versioned OSM tag drafts with a map-first guided editor; no uploads or topology mutations. */
(function(root){
  'use strict';
  const validID=n=>Number.isSafeInteger(n)&&n>0;
  const xmlText=s=>![...s].some(c=>{const n=c.codePointAt(0);return !(n===9||n===10||n===13||(n>=32&&n<=0xD7FF)||(n>=0xE000&&n<=0xFFFD)||(n>=0x10000&&n<=0x10FFFF));});
  const normLon=lng=>((lng+180)%360+360)%360-180;
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
  // A map position kept next to a draft so ways can be found again; it never reaches the export.
  const viewCenter=raw=>Array.isArray(raw)&&raw.length===2&&raw.every(Number.isFinite)&&Math.abs(raw[0])<=180&&Math.abs(raw[1])<=90?[raw[0],raw[1]]:undefined;
  function validateDraft(d){
    const base=d.base?element(d.base):null, value=element(d.value,!base), center=viewCenter(d.center);
    if(base&&(base.type!==value.type||base.id!==value.id||base.version!==value.version||base.lon!==value.lon||base.lat!==value.lat||JSON.stringify(base.nodes)!==JSON.stringify(value.nodes)))throw Error('Bestehende Geometrien und Versionen dürfen nicht verändert werden.');
    if(!base&&!Object.values(value.tags).some(v=>v.trim()))throw Error('Ein neuer Punkt benötigt mindestens einen Tag.');
    return {base,value,...(center?{center}:{})};
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

  // Outline and centre of a way from an API `/full` response, used for the map highlight.
  function wayShape(elements,id){
    const nodes=new Map((elements||[]).filter(e=>e.type==='node'&&Number.isFinite(e.lon)&&Number.isFinite(e.lat)).map(n=>[n.id,[n.lon,n.lat]]));
    const way=(elements||[]).find(e=>e.type==='way'&&e.id===id);
    const coordinates=(way?.nodes||[]).map(ref=>nodes.get(ref)).filter(Boolean);
    if(!coordinates.length)return null;
    const lons=coordinates.map(c=>c[0]),lats=coordinates.map(c=>c[1]);
    const west=Math.min(...lons),east=Math.max(...lons),south=Math.min(...lats),north=Math.max(...lats);
    const first=coordinates[0],last=coordinates[coordinates.length-1];
    return {coordinates,closed:coordinates.length>3&&first[0]===last[0]&&first[1]===last[1],center:[(west+east)/2,(south+north)/2],bounds:[[west,south],[east,north]]};
  }
  // How many metres a fingertip-sized click target covers at this latitude and zoom.
  function pickRadiusMeters(lat,zoom,pixels=26){
    const metresPerPixel=156543.03392*Math.cos(lat*Math.PI/180)/Math.pow(2,zoom);
    return Math.max(6,Math.min(metresPerPixel*pixels,500));
  }
  const formatDistance=m=>!Number.isFinite(m)?'':m<1000?`${Math.max(1,Math.round(m))} m`:`${(m/1000).toFixed(1).replace('.',',')} km`;

  const iconHTML=id=>`<svg class="ui-icon" aria-hidden="true" focusable="false" viewBox="0 0 24 24"><use href="#${id}"/></svg>`;
  const PROPS=new Set(['value','type','hidden','disabled','placeholder','rows','href','id','inputMode','maxLength','target','rel','className','innerHTML']);
  // Small element factory; text always goes through textContent so OSM data cannot inject markup.
  function h(tag,props={},...kids){
    const node=document.createElement(tag);
    for(const [name,value] of Object.entries(props)){
      if(value==null||value===false)continue;
      if(name==='text')node.textContent=value;
      else if(name==='class')node.className=value;
      else if(name==='on'){for(const [event,handler] of Object.entries(value))node.addEventListener(event,handler);}
      else if(PROPS.has(name))node[name]=value;
      else node.setAttribute(name,value===true?'':String(value));
    }
    node.append(...kids.filter(Boolean));
    return node;
  }

  function create(map,options={}){
    const P=root.OSMPresets;
    if(!P)throw Error('OSMPresets muss vor dem Editor geladen werden.');
    const el=id=>document.getElementById(id),status=el('osmEditorStatus'),key='osmmini.osm-drafts.v1';
    const say=text=>{status.textContent=text;};
    const TABS=[['find','osmTabFind','osmPanelFind'],['edit','osmTabEdit','osmPanelEdit'],['drafts','osmTabDrafts','osmPanelDrafts']];
    let drafts=[],current=null,working=[],dirty=false,busy=false,viewActive=false,placing=false,tab='find';
    let candidates=[],highlighted='',nearbyPoint=null,lastSearch=null,missPoint=null,presetOpen=false,customKind=false,renderedKind='';
    let undo=[],redo=[],checkedFor='',conflicts=[],validForm=false;
    const fieldNodes=new Map();
    try{const raw=localStorage.getItem(key);if(raw)drafts=restore(raw);}catch{say('Gespeicherte Entwürfe konnten nicht geladen werden.');}
    let saved=JSON.stringify(drafts);

    const versions=()=>JSON.stringify(drafts.filter(d=>d.base).map(d=>[d.base.type,d.base.id,d.base.version]).sort());
    const sameObject=(a,b)=>a.value.id===b.value.id&&a.value.type===b.value.type;
    const isCurrent=d=>!!current&&sameObject(d,current);
    const positionOf=d=>d.center||(d.value.type==='node'?[d.value.lon,d.value.lat]:null);
    const kindName=type=>type==='node'?'Punkt':'Weg / Fläche';
    const fieldLabel=P.keyLabel;
    const label=e=>e.tags.name||P.presetForTags(e.tags)?.label||P.categoryLabel(P.primaryCategory(e.tags))||(e.type==='node'?'Unbenannter Ort':'Unbenannter Weg / Fläche');
    const iconFor=e=>P.presetForTags(e.tags)?.icon||P.categoryIcon(P.primaryCategory(e.tags));
    const trimmed=()=>working.map(([k,v])=>[k.trim(),v.trim()]);
    const valueOf=k=>working.find(row=>row[0]===k)?.[1]||'';
    function setValue(k,value){
      const index=working.findIndex(row=>row[0]===k);
      if(!value.trim()){if(index>=0)working.splice(index,1);}
      else if(index>=0)working[index][1]=value;
      else working.push([k,value]);
    }
    function tagsNow(){try{return tags(trimmed());}catch{return Object.fromEntries(trimmed().filter(([k,v])=>k&&v));}}
    function userError(error){
      if(error.name==='TimeoutError')return 'Die Antwort dauert zu lange. Bitte erneut versuchen.';
      if(error.name==='TypeError')return 'Verbindung fehlgeschlagen. Prüfe deine Internetverbindung und versuche es erneut.';
      if(error.name==='SyntaxError')return 'Die Datei oder Antwort konnte nicht gelesen werden. Verwende eine hier erstellte JSON-Sicherung oder lade den Ort erneut.';
      return error.message;
    }

    // ── Modes: the editor owns map clicks while the view is open on "Finden" or while placing a point.
    const mode=()=>placing?'place':viewActive&&tab==='find'&&!busy?'pick':null;
    function applyMode(){
      const m=mode();
      map.getCanvas().style.cursor=m==='place'?'crosshair':m==='pick'?'pointer':'';
      el('osmNew').setAttribute('aria-pressed',String(placing));
      el('osmNew').textContent=placing?'Punktsetzen abbrechen':'Neuen Ort eintragen';
      el('osmPickText').textContent=placing?'Klicke auf die Karte, um den neuen Ort zu setzen. Abbrechen mit Escape.':'Wähle auf der Karte einen Ort aus, den du bearbeiten möchtest.';
      el('osmPickHint').setAttribute('data-active',String(!!m));
      el('osmEditView').setAttribute('data-mode',m||'');
    }
    function cancel(){placing=false;applyMode();}
    function setTab(name,focus=false){
      tab=name;
      for(const [id,buttonId,panelId] of TABS){
        const selected=id===name,button=el(buttonId);
        button.setAttribute('aria-selected',String(selected));
        button.setAttribute('tabindex',selected?'0':'-1');
        el(panelId).hidden=!selected;
        if(selected&&focus)button.focus?.();
      }
      if(name!=='find')el('osmPickMiss').hidden=true;
      el('osmEditView').setAttribute('data-tab',name);
      applyMode();
    }
    function setBusy(value){if(value)placing=false;busy=value;applyMode();syncUI();}

    // ── Drafts, persistence, undo/redo
    function persist(record=true){
      const next=JSON.stringify(drafts);
      if(record&&next!==saved){undo.push(saved);if(undo.length>30)undo.shift();redo=[];}
      saved=next;
      try{localStorage.setItem(key,JSON.stringify({version:1,drafts}));return '';}catch{return ' Lokale Speicherung fehlgeschlagen; bitte exportieren.';}
    }
    function canSwitch(){
      if(dirty){say('Du hast ungespeicherte Änderungen. Speichere sie oder verwirf sie im Reiter „Bearbeiten“.');setTab('edit');el('osmSelected').focus?.();return false;}
      return !busy;
    }
    function closeCurrent(){current=null;working=[];dirty=false;presetOpen=false;customKind=false;renderForm();render();syncUI();}

    // ── Analysis of the working tags: validity, diff, hints
    const display=(k,v)=>{
      const option=P.fields[k]?.options?.find(([raw])=>raw===v)?.[1]||Object.values(P.presets).find(p=>Object.keys(p.tags).length===1&&p.tags[k]===v)?.label;
      return JSON.stringify(option?`${option} (${v})`:v);
    };
    function analyze(){
      const list=el('osmDiff');list.replaceChildren();validForm=false;
      let message='';
      const counts=new Map();working.forEach(([k])=>counts.set(k.trim(),(counts.get(k.trim())||0)+1));
      const flags=working.map(([k,v])=>{let invalid=false;try{tags([[k.trim(),v.trim()]]);}catch{invalid=true;}return invalid||(k.trim()&&counts.get(k.trim())>1);});
      [...el('osmTags').children].forEach((row,i)=>{
        if(!working[i])return;
        const [keyInput,valueInput,remove]=row.children,name=fieldLabel(working[i][0].trim())||'Eigenschaft';
        keyInput.setAttribute('aria-invalid',String(flags[i]));valueInput.setAttribute('aria-invalid',String(flags[i]));
        valueInput.setAttribute('aria-label',name+' – Wert');remove.setAttribute('aria-label',name+' entfernen');
      });
      let delta=[];
      if(current){
        try{
          const next=tags(trimmed());delta=changes(current.base?.tags||{},next);
          el('osmSelected').textContent=label({...current.value,tags:next});
          for(const d of delta){
            const item=document.createElement('li');
            item.textContent=`${fieldLabel(d.key)}: ${d.before===undefined?'neu':display(d.key,d.before)} → ${d.after===undefined?'wird entfernt':display(d.key,d.after)}`;
            list.append(item);
          }
          if(!current.base&&!Object.values(next).some(v=>v.trim()))message='Wähle eine Art aus oder ergänze eine Eigenschaft für den neuen Ort.';
          else validForm=!!delta.length||drafts.some(isCurrent);
        }catch(e){message=e.message;}
        if(!delta.length&&!message){const item=document.createElement('li');item.textContent='Noch nichts geändert.';list.append(item);}
      }
      const changed=new Set(delta.map(d=>d.key));
      for(const [k,node] of fieldNodes){
        const rowIndex=working.findIndex(row=>row[0].trim()===k),invalid=rowIndex>=0&&flags[rowIndex];
        if(node.field.type!=='choice')node.input.setAttribute('aria-invalid',String(!!invalid));
        node.wrap.classList.toggle('is-changed',changed.has(k));
        const hint=invalid?'':P.checkValue(node.field,valueOf(k));
        node.warn.textContent=hint;node.warn.hidden=!hint;
      }
      el('osmDiffSummary').textContent=delta.length?`Änderungen (${delta.length})`:'Änderungen';
      if(el('osmValidation').textContent!==message)el('osmValidation').textContent=message;
      const wantedKind=P.presetKeyForTags(tagsNow());
      if(current&&wantedKind!==renderedKind){renderPresets();renderFields();}
      syncUI();
    }

    // ── Form rendering
    function fieldNode(field){
      const id='osmField-'+field.key.replace(/[^a-z0-9]/gi,'-'),labelId=id+'-label',warnId=id+'-warn';
      const wrap=h('div',{class:'osm-field','data-key':field.key});
      const warn=h('p',{id:warnId,class:'osm-field-warn',hidden:true});
      let input,set,control;
      if(field.type==='choice'){
        const options=[...field.options];
        const known=value=>options.some(([raw])=>raw===value);
        const buttons=new Map();
        control=h('div',{class:'osm-choice',role:'group','aria-labelledby':labelId});
        const press=raw=>{setValue(field.key,valueOf(field.key)===raw?'':raw);dirty=true;set(valueOf(field.key));renderTable();analyze();};
        const add=(raw,text)=>{const button=h('button',{type:'button',class:'osm-choice-button',text,'aria-pressed':'false',on:{click:()=>press(raw)}});buttons.set(raw,button);control.append(button);};
        options.forEach(([raw,text])=>add(raw,text));
        set=value=>{
          if(value&&!known(value)&&!buttons.has(value))add(value,value);
          for(const [raw,button] of buttons)button.setAttribute('aria-pressed',String(raw===value));
        };
        input=control;
        wrap.append(h('span',{id:labelId,class:'osm-field-label',text:field.label}),control);
      }else{
        input=h('input',{id,type:field.type==='hours'?'text':field.type==='number'?'text':field.type,placeholder:field.placeholder||'',class:'setting-input','aria-describedby':warnId+(field.hint?' '+id+'-hint':'')});
        if(field.type==='number')input.inputMode='numeric';
        if(field.type==='tel')input.setAttribute('autocomplete','off');
        input.addEventListener('input',()=>{setValue(field.key,input.value);dirty=true;renderTable();analyze();});
        set=value=>{if(input.value!==value)input.value=value;};
        control=input;
        wrap.append(h('label',{id:labelId,class:'osm-field-label','for':id,text:field.label}),control);
        if(field.suggestions){
          const chips=h('div',{class:'osm-suggestions','aria-label':field.label+' – Vorschläge',role:'group'});
          for(const [raw,text] of field.suggestions)chips.append(h('button',{type:'button',class:'osm-suggestion',text,on:{click:()=>{setValue(field.key,raw);dirty=true;set(raw);renderTable();analyze();input.focus?.();}}}));
          wrap.append(chips);
        }
      }
      if(field.hint)wrap.append(h('p',{id:id+'-hint',class:'osm-field-hint',text:field.hint}));
      wrap.append(warn);
      set(valueOf(field.key));
      fieldNodes.set(field.key,{field,input,wrap,warn,set});
      return wrap;
    }
    function renderFields(){
      const box=el('osmFields');box.replaceChildren();fieldNodes.clear();
      const kind=P.presetKeyForTags(tagsNow());renderedKind=kind;
      const show=!!current&&(current.base||kind||customKind);
      box.hidden=!show;
      if(!show)return;
      const {fields,address}=P.fieldsFor(tagsNow());
      for(const field of fields)box.append(fieldNode(field));
      const details=h('details',{class:'osm-advanced osm-address'},h('summary',{text:'Adresse'}),...address.map(fieldNode));
      details.open=address.some(f=>valueOf(f.key));
      box.append(details);
    }
    function renderPresets(focusFirst=false){
      const wrap=el('osmPresetChips');wrap.replaceChildren();let first=null;
      const kind=P.presetKeyForTags(tagsNow()),preset=P.presets[kind];
      el('osmPresetWrap').hidden=!current||!!current.base;
      if(!current||current.base)return;
      if(preset&&!presetOpen){
        wrap.append(h('div',{class:'osm-preset-current'},h('span',{class:'osm-preset-icon','aria-hidden':'true',text:preset.icon}),h('strong',{text:preset.label}),h('button',{type:'button',class:'btn btn-ghost',text:'Ändern','aria-label':'Art des Ortes ändern',on:{click:()=>{presetOpen=true;renderPresets(true);}}})));
        return;
      }
      for(const group of [...new Set(Object.values(P.presets).map(p=>p.group))]){
        const grid=h('div',{class:'osm-preset-grid',role:'group','aria-label':group});
        for(const [k,p] of Object.entries(P.presets).filter(([,p])=>p.group===group)){const button=h('button',{type:'button',class:'osm-preset','aria-pressed':String(k===kind),on:{click:()=>applyPreset(k)}},h('span',{class:'osm-preset-icon','aria-hidden':'true',text:p.icon}),h('span',{text:p.label}));first??=button;grid.append(button);}
        wrap.append(h('div',{class:'osm-preset-group'},h('h4',{text:group}),grid));
      }
      if(focusFirst)first?.focus?.();
      wrap.append(h('button',{type:'button',class:'btn btn-ghost osm-preset-other',text:'Andere Art – eigene Eigenschaften',on:{click:()=>{customKind=true;presetOpen=false;renderPresets();renderFields();el('osmAdvancedTags').open=true;el('osmAddTag').click();}}}));
    }
    function applyPreset(k){
      const preset=P.presets[k];
      if(!current||current.base||!preset){say('Wähle zuerst eine Art für den neuen Ort.');return;}
      const previous=P.presetForTags(tagsNow());
      if(previous)for(const name of Object.keys(previous.tags))setValue(name,'');
      for(const [name,value] of Object.entries(preset.tags))setValue(name,value);
      dirty=true;presetOpen=false;
      renderPresets();renderFields();renderTable();analyze();
      say(preset.label+' gewählt. Ergänze nur Angaben, die du sicher kennst, und speichere den Entwurf.');
      [...fieldNodes.values()][0]?.input.focus?.();
    }
    function rowNode(pair){
      const keyInput=h('input',{value:pair[0],placeholder:'Schlüssel','aria-label':'OSM-Schlüssel','aria-describedby':'osmValidation'});
      const valueInput=h('textarea',{value:pair[1],rows:1,placeholder:'Wert','aria-describedby':'osmValidation'});
      const remove=h('button',{type:'button',innerHTML:iconHTML('icon-close')});
      const div=h('div',{class:'osm-tag-row'},keyInput,valueInput,remove);
      const edited=()=>{dirty=true;for(const [name,node] of fieldNodes)node.set(valueOf(name));analyze();};
      keyInput.addEventListener('input',()=>{pair[0]=keyInput.value;edited();});
      valueInput.addEventListener('input',()=>{pair[1]=valueInput.value;edited();});
      remove.addEventListener('click',()=>{
        const index=working.indexOf(pair);working.splice(index,1);dirty=true;
        renderTable();for(const [name,node] of fieldNodes)node.set(valueOf(name));analyze();
        const next=el('osmTags').children[index]||el('osmTags').children[index-1];
        (next?.children[0]||el('osmAddTag')).focus?.();
      });
      return div;
    }
    function renderTable(){const box=el('osmTags');box.replaceChildren();working.forEach(pair=>box.append(rowNode(pair)));}
    function renderForm(){
      el('osmForm').hidden=!current;el('osmEmpty').hidden=!!current;
      if(!current){el('osmDuplicates').hidden=true;return;}
      const {value,base}=current;
      el('osmObjectMeta').textContent=base?`${kindName(value.type)} · OSM-ID ${value.id} · Version ${value.version}`:`Neuer Ort · ${value.lat.toFixed(5)}, ${value.lon.toFixed(5)}`;
      const link=el('osmOsmLink');link.hidden=!base;if(base)link.href=`https://www.openstreetmap.org/${value.type}/${value.id}`;
      renderPresets();renderFields();renderTable();
    }
    function open(d){
      current=structuredClone(d);dirty=false;working=Object.entries(current.value.tags);
      presetOpen=!current.base&&!P.presetKeyForTags(current.value.tags);customKind=false;
      el('osmDuplicates').hidden=true;el('osmDuplicates').replaceChildren();
      el('osmSelected').textContent=label(current.value);
      renderForm();analyze();setTab('edit');render();
      el('osmSelected').focus?.();
    }

    // ── Sync of buttons, badges and status cards with the current state
    function syncUI(){
      el('osmFormFields').disabled=busy;
      el('osmFormFields').setAttribute('aria-busy',String(busy));
      el('osmCandidates').setAttribute('aria-busy',String(busy));
      for(const id of ['osmNearby','osmNew','osmLoad','osmImport'])el(id).disabled=busy;
      el('osmNearby').textContent=busy?'Bitte warten …':'Suchen';
      el('osmSave').disabled=busy||!current||!validForm;
      el('osmDiscard').disabled=busy;
      el('osmDiscard').textContent=dirty?'Änderungen verwerfen':'Schließen';
      el('osmEditState').textContent=dirty?'Nicht gespeichert':'Keine offenen Änderungen';
      el('osmEditState').setAttribute('data-state',dirty?'dirty':'clean');
      el('osmUndo').disabled=busy||dirty||!undo.length;
      el('osmRedo').disabled=busy||dirty||!redo.length;
      el('osmCheck').disabled=busy||dirty||!drafts.some(d=>d.base);
      for(const id of ['osmExport','osmBackup'])el(id).disabled=busy||dirty||!drafts.length;
      const count=el('osmDraftCount');count.textContent=String(drafts.length);count.hidden=!drafts.length;
      el('osmTabDrafts').setAttribute('aria-label',`Entwürfe, ${drafts.length} im Arbeitsstand`);
      el('osmDraftSummary').textContent=drafts.length?`${drafts.length} ${drafts.length===1?'Entwurf':'Entwürfe'} im Arbeitsstand.${dirty?' Offene Änderungen zuerst speichern oder verwerfen.':''}`:'Noch keine Entwürfe. Wähle einen Ort auf der Karte oder trage einen neuen ein.';
      el('osmCheckState').textContent=!drafts.length?'':checkedFor===versions()&&conflicts.length?'OSM wurde inzwischen geändert. Sichere den Arbeitsstand und löse die Konflikte in einem OSM-Editor.':!drafts.some(d=>d.base)?'Nur neue Orte. Bitte vor der Veröffentlichung prüfen, ob sie bereits in OSM existieren.':checkedFor===versions()?'Beim letzten Vergleich waren die OSM-Versionen aktuell. Vor der Veröffentlichung erneut prüfen.':'Noch nicht mit dem aktuellen OSM-Stand verglichen. Internetverbindung erforderlich.';
      const overview=el('osmDraftOverview');overview.replaceChildren();
      if(drafts.length){
        const outdated=checkedFor!==versions()&&drafts.some(d=>d.base);
        const state=conflicts.length&&!outdated?'warn':outdated?'pending':'ok';
        overview.setAttribute('data-state',state);
        const title=conflicts.length&&!outdated?`${conflicts.length} Versionswarnung${conflicts.length===1?'':'en'}`:outdated?'Vor dem Export mit OSM vergleichen':'Export bereit';
        const next=h('button',{type:'button',class:'btn btn-ghost',text:conflicts.length&&!outdated?'Warnung anzeigen':outdated?'Jetzt vergleichen':'Entwürfe ansehen',on:{click:()=>{
          if(conflicts.length&&!outdated){const issue=conflicts[0].match(/^(node|way)\/(\d+)/),draft=issue&&drafts.find(d=>d.value.type===issue[1]&&String(d.value.id)===issue[2]);if(draft&&canSwitch())open(draft);}
          else if(outdated)el('osmCheck').focus?.();
          else el('osmDrafts').scrollIntoView?.({block:'nearest',behavior:'smooth'});
        }}});
        overview.append(h('strong',{text:title}));
        if(state!=='ok')overview.append(next);
      }else overview.removeAttribute('data-state');
      if(checkedFor===versions()&&conflicts.length)el('osmExport').disabled=true;
    }
    function draftNode(d,index){
      const changeCount=d.base?changes(d.base.tags,d.value.tags).length:0;
      const meta=`${kindName(d.value.type)} · ${d.base?`${changeCount} ${changeCount===1?'Änderung':'Änderungen'}`:'neu'}`;
      const name=label(d.value);
      const edit=h('button',{type:'button',class:'osm-draft-main','aria-label':`${name} bearbeiten`,on:{click:()=>{if(canSwitch()){cancel();open(d);flyToObject(d);}}}},h('span',{class:'osm-draft-icon','aria-hidden':'true',text:iconFor(d.value)}),h('span',{class:'osm-draft-text'},h('strong',{text:name}),h('small',{text:meta})));
      const locate=h('button',{type:'button',class:'osm-icon-button','aria-label':`${name} auf der Karte zeigen`,title:'Auf der Karte zeigen',innerHTML:iconHTML('icon-location'),on:{click:()=>flyToObject(d)}});
      locate.disabled=!positionOf(d);
      const remove=h('button',{type:'button',class:'osm-icon-button osm-danger','aria-label':`${name} aus dem Arbeitsstand entfernen`,title:'Entfernen',innerHTML:iconHTML('icon-close'),on:{click:()=>{
        if(!canSwitch())return;
        drafts.splice(index,1);
        say('Entwurf entfernt. Mit „Rückgängig“ wiederherstellen.'+persist());refresh();el('osmDraftSummary').focus?.();
      }}});
      return h('li',{class:'osm-draft'},edit,locate,remove);
    }
    function refresh(){
      syncUI();
      const list=el('osmDrafts');list.replaceChildren();
      drafts.forEach((d,i)=>list.append(draftNode(d,i)));
      render();
    }

    // ── Candidate list and map layers
    function renderCandidates(){
      const list=el('osmCandidates');list.replaceChildren();
      for(const c of candidates){
        const category=P.categoryLabel(c.category),name=P.isRawLabel(c.label,c.category)?category||c.label||'Ort':c.label,distance=formatDistance(c.distance);
        const meta=[category&&category!==name?category:'',kindName(c.type),distance].filter(Boolean).join(' · ');
        const button=h('button',{type:'button',class:'osm-candidate','aria-label':`${name}, ${meta}, bearbeiten`,on:{click:()=>load(c.type,c.id),mouseenter:()=>highlight(c),mouseleave:()=>highlight(null),focus:()=>highlight(c),blur:()=>highlight(null)}},h('span',{class:'osm-draft-icon','aria-hidden':'true',text:P.categoryIcon(c.category)}),h('span',{class:'osm-draft-text'},h('strong',{text:name}),h('small',{text:meta})),h('span',{class:'osm-candidate-go','aria-hidden':'true',innerHTML:iconHTML('icon-chevron')}));
        list.append(h('li',{},button));
      }
      el('osmCandidatesEmpty').hidden=!!candidates.length;
      render();
    }
    function highlight(c){highlighted=c?c.type+'/'+c.id:'';render();}
    // The map throws while its style is still loading; render() then retries shortly instead of dropping the update.
    function put(id,data,layers){
      try{
        const source=map.getSource(id);
        if(source)source.setData(data);else map.addSource(id,{type:'geojson',data});
        for(const layer of layers)if(!map.getLayer(layer.id))map.addLayer({...layer,source:id});
        return true;
      }catch{return false;}
    }
    let retry=null,attempts=0;
    function render(){
      const point=(coordinates,properties)=>({type:'Feature',properties,geometry:{type:'Point',coordinates}});
      const collection=features=>({type:'FeatureCollection',features});
      const shape=current?.shape;
      let complete=true;
      complete&=put('osm-selection',collection(shape?[{type:'Feature',properties:{},geometry:shape.closed?{type:'Polygon',coordinates:[shape.coordinates]}:{type:'LineString',coordinates:shape.coordinates}}]:[]),[
        {id:'osm-selection-fill',type:'fill',filter:['==','$type','Polygon'],paint:{'fill-color':'#2563eb','fill-opacity':.16}},
        {id:'osm-selection-line',type:'line',paint:{'line-color':'#2563eb','line-width':4}},
      ]);
      complete&=put('osm-candidates',collection(current?[]:candidates.filter(c=>c.coordinates).map(c=>point(c.coordinates,{active:highlighted===c.type+'/'+c.id}))),[
        {id:'osm-candidates-points',type:'circle',paint:{'circle-radius':['case',['get','active'],10,6],'circle-color':['case',['get','active'],'#2563eb','#60a5fa'],'circle-opacity':.9,'circle-stroke-width':2,'circle-stroke-color':'#fff'}},
      ]);
      const shown=drafts.filter(d=>!isCurrent(d));if(current)shown.push(current);
      complete&=put('osm-drafts',collection(shown.map(d=>({d,at:d.value.type==='node'?[d.value.lon,d.value.lat]:d.center})).filter(x=>x.at).map(x=>point(x.at,{selected:isCurrent(x.d)}))),[
        {id:'osm-drafts-points',type:'circle',paint:{'circle-radius':['case',['get','selected'],10,7],'circle-color':['case',['get','selected'],'#2563eb','#8b5cf6'],'circle-stroke-width':2,'circle-stroke-color':'#fff'}},
      ]);
      if(complete)attempts=0;
      else if(!retry&&attempts++<40)retry=setTimeout(()=>{retry=null;render();},250);
      options.onChange?.();
    }
    function flyToObject(target){
      if(target.shape?.bounds&&map.fitBounds){map.fitBounds(target.shape.bounds,{maxZoom:19,padding:60});return;}
      const at=positionOf(target);
      if(at)map.flyTo({center:at,zoom:Math.max(map.getZoom?.()??0,18)});
    }

    // A list built around an old map position is misleading once the map has moved on.
    function movedAway(){
      const c=map.getCenter();
      return !lastSearch||Math.hypot((c.lng-lastSearch.lng)*Math.cos(c.lat*Math.PI/180),c.lat-lastSearch.lat)*111320>300;
    }

    // ── Local index queries (own server, nothing leaves the machine)
    async function fetchPois(params,timeout=15000){
      const response=await fetch('/api/v1/geo/pois?'+new URLSearchParams(params),{signal:AbortSignal.timeout(timeout)});
      if(!response.ok)throw Error('Lokale Suche fehlgeschlagen.');
      const body=await response.json();
      return (body.features||[]).filter(f=>f.properties&&validID(Number(f.properties.osm_id))).map(f=>({type:f.properties.kind==='node'?'node':'way',id:Number(f.properties.osm_id),label:f.properties.label,category:f.properties.category,distance:f.properties.distance_m,coordinates:f.geometry?.coordinates}));
    }
    async function search(){
      if(busy)return;
      const query=el('osmSearch').value.trim(),point=nearbyPoint||map.getCenter();nearbyPoint=null;lastSearch={lng:point.lng,lat:point.lat};
      setBusy(true);el('osmPickMiss').hidden=true;
      say(query?`Suche „${query}“ im Umkreis von 5 km …`:'Suche erfasste Orte im Umkreis von 500 m …');
      try{
        candidates=await fetchPois({lat:point.lat,lon:normLon(point.lng),radius_m:query?5000:500,limit:50,...(query?{q:query}:{})});
        renderCandidates();
        say(candidates.length?`${candidates.length} ${candidates.length===1?'Ort':'Orte'} gefunden. Wähle einen aus, um ihn zu bearbeiten.`:'Keine erfassten Orte gefunden. Verschiebe die Karte, ändere die Suche oder trage einen neuen Ort ein.');
      }catch(e){say(userError(e));}finally{setBusy(false);}
    }
    async function pick(lngLat){
      if(busy||!canSwitch())return;
      el('osmPickMiss').hidden=true;
      const radius=Math.round(pickRadiusMeters(lngLat.lat,map.getZoom?.()??17));
      let hit=null;
      setBusy(true);say('Suche erfassten Ort an dieser Stelle …');
      try{
        const found=await fetchPois({lat:lngLat.lat,lon:normLon(lngLat.lng),radius_m:radius,limit:10},8000);
        if(found.length)hit=found[0];
        else{missPoint=lngLat;el('osmPickMiss').hidden=false;say('Hier ist kein erfasster Ort. Zoome näher heran oder trage einen neuen Ort ein.');}
      }catch(e){say(userError(e));}finally{setBusy(false);}
      if(hit)await load(hit.type,hit.id);
    }
    async function checkDuplicates(value){
      const box=el('osmDuplicates');box.hidden=true;box.replaceChildren();
      try{
        const found=await fetchPois({lat:value.lat,lon:value.lon,radius_m:30,limit:4},6000);
        if(!found.length||!current||current.value.id!==value.id)return;
        box.append(h('strong',{text:'Schon erfasst? Bearbeite stattdessen:'}));
        for(const c of found.slice(0,3)){
          const name=P.isRawLabel(c.label,c.category)?P.categoryLabel(c.category)||'Ort':c.label,distance=formatDistance(c.distance);
          box.append(h('button',{type:'button',class:'osm-dup','aria-label':`${name}, ${distance} entfernt, stattdessen bearbeiten`,on:{click:async()=>{closeCurrent();await load(c.type,c.id);}}},h('span',{text:name}),h('small',{text:distance})));
        }
        box.hidden=false;
      }catch{/* the hint is optional */}
    }

    // ── Loading and placing
    async function load(type,id){
      if(!canSwitch())return;
      if(!['node','way'].includes(type)||!validID(Number(id))){say('Gib die numerische OSM-ID ein, zum Beispiel 123456. Du findest sie auf der Objektseite von OpenStreetMap.');return;}
      const existing=drafts.find(d=>d.value.type===type&&d.value.id===Number(id));
      if(existing){cancel();open(existing);flyToObject(existing);say('Vorhandenen Entwurf geöffnet. Die Basisversion bleibt erhalten.');return;}
      id=String(Number(id));
      cancel();setBusy(true);say('Aktuellen Stand von api.openstreetmap.org laden …');
      try{
        const response=await fetch(`https://api.openstreetmap.org/api/0.6/${type}/${id}${type==='way'?'/full':''}.json`,{signal:AbortSignal.timeout(15000),credentials:'omit'});
        if(!response.ok)throw Error(response.status===404||response.status===410?'Dieser Ort ist auf OSM nicht verfügbar. Prüfe die ID oder wähle einen anderen Ort.':response.status===429?'OSM erhält gerade zu viele Anfragen. Warte kurz und versuche es erneut.':`OSM konnte den Ort nicht laden (HTTP ${response.status}). Bitte erneut versuchen.`);
        const body=await response.json(),base=element(body.elements?.find(e=>e.type===type&&e.id===Number(id)));
        if(dirty)throw Error('Offene Änderungen erst speichern oder verwerfen, dann erneut laden.');
        const shape=base.type==='way'?wayShape(body.elements,base.id):null;
        open({base,value:structuredClone(base),center:shape?shape.center:[base.lon,base.lat],shape});
        flyToObject(current);
        say('Ort geladen. Ändere die Angaben und speichere sie als Entwurf.');
      }catch(e){say(userError(e));}finally{setBusy(false);}
    }
    function place(lngLat){
      const id=Math.min(0,...drafts.map(d=>d.value.id))-1;
      try{
        const value=element({type:'node',id,lat:lngLat.lat,lon:normLon(lngLat.lng),tags:{}},true);
        placing=false;applyMode();
        open({base:null,value,center:[value.lon,value.lat]});dirty=true;analyze();
        say('Position gewählt. Wähle die Art des Ortes und ergänze, was du weißt.');
        checkDuplicates(value);
      }catch(e){say(userError(e));}
    }
    function mapClick(event){
      if(event.originalEvent?.target?.closest?.('.maplibregl-marker, .maplibregl-popup'))return;
      const m=mode();
      if(m==='place')return place(event.lngLat);
      if(m==='pick')return pick(event.lngLat);
    }

    // ── Save, discard, export
    function save(){
      try{
        if(!current)return;
        const d=validateDraft({...current,value:{...current.value,tags:tags(trimmed())}});
        const index=drafts.findIndex(x=>sameObject(x,d));
        if(!d.base&&!Object.keys(d.value.tags).length)throw Error('Ein neuer Punkt benötigt mindestens einen Tag.');
        let message;
        if(d.base&&!changes(d.base.tags,d.value.tags).length){if(index>=0)drafts.splice(index,1);message='Keine Änderungen; das Objekt ist nicht im Export.';}
        else{
          if(index<0){if(drafts.length>=100)throw Error('Maximal 100 Entwürfe.');drafts.push(d);}else drafts[index]=d;
          message=`Entwurf gespeichert (${drafts.length} im Arbeitsstand). Wähle den nächsten Ort oder öffne „Entwürfe“ zum Export.`;
        }
        closeCurrent();say(message+persist());refresh();setTab('find');
        status.focus?.();
      }catch(e){say(userError(e));}finally{syncUI();}
    }
    function discard(){
      closeCurrent();setTab('find');
      say('Bearbeitung geschlossen. Gespeicherte Entwürfe bleiben erhalten.');
      el('osmSearch').focus?.();
    }
    function download(content,name,type){const url=URL.createObjectURL(new Blob([content],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}

    // ── Wiring
    el('osmSearchForm').addEventListener('submit',event=>{event.preventDefault?.();return search();});
    el('osmNew').addEventListener('click',()=>{
      if(!canSwitch())return;
      if(placing){cancel();say('Punktsetzen beendet.');return;}
      options.onStart?.();placing=true;el('osmPickMiss').hidden=true;applyMode();
      say('Punktsetzen aktiv. Klicke auf die genaue Position des neuen Ortes.');syncUI();
    });
    el('osmPickPlace').addEventListener('click',()=>{if(missPoint&&canSwitch()){const point=missPoint;missPoint=null;el('osmPickMiss').hidden=true;placing=true;place(point);}});
    el('osmLoad').addEventListener('click',()=>load(el('osmType').value,el('osmID').value));
    el('osmAddTag').addEventListener('click',()=>{const pair=['',''];working.push(pair);dirty=true;renderTable();analyze();el('osmTags').children[el('osmTags').children.length-1]?.children[0].focus?.();});
    el('osmSave').addEventListener('click',save);
    el('osmDiscard').addEventListener('click',discard);
    el('osmLocate').addEventListener('click',()=>{if(current)flyToObject(current);});
    el('osmEmptyFind').addEventListener('click',()=>setTab('find',true));
    for(const [id,buttonId] of TABS){
      el(buttonId).addEventListener('click',()=>setTab(id,false));
      el(buttonId).addEventListener('keydown',event=>{
        const order=TABS.map(t=>t[0]),at=order.indexOf(id);
        const next={ArrowRight:order[(at+1)%order.length],ArrowLeft:order[(at+order.length-1)%order.length],Home:order[0],End:order[order.length-1]}[event.key];
        if(next){event.preventDefault?.();setTab(next,true);}
      });
    }
    el('osmExport').addEventListener('click',()=>{try{if(busy)throw Error('Laufenden Vorgang zuerst abschließen lassen.');if(checkedFor===versions()&&conflicts.length)throw Error('Versionskonflikte: Entwurf sichern und in einem OSM-Editor abgleichen.');if(dirty)throw Error('Offene Änderungen erst speichern oder verwerfen.');download(osc(drafts),'osm-entwurf.osc','application/xml');say('Änderungsdatei exportiert. Vor einem Upload Basisversionen und Änderungen in einem OSM-Editor prüfen.');}catch(e){say(userError(e));}});
    el('osmBackup').addEventListener('click',()=>{if(dirty){say('Offene Änderungen erst speichern oder verwerfen.');return;}download(JSON.stringify({version:1,drafts},null,2),'osm-entwurf.json','application/json');});
    for(const id of ['osmUndo','osmRedo']){
      // Resolve stacks dynamically because a new edit discards redo history.
      el(id).addEventListener('click',()=>{
        if(!canSwitch())return;
        const source=id==='osmUndo'?undo:redo,target=id==='osmUndo'?redo:undo;if(!source.length)return;
        target.push(JSON.stringify(drafts));drafts=JSON.parse(source.pop());closeCurrent();
        say('Entwurfsänderung '+(id==='osmUndo'?'rückgängig gemacht.':'wiederhergestellt.')+persist(false));refresh();
      });
    }
    el('osmCheck').addEventListener('click',async()=>{
      if(!canSwitch())return;setBusy(true);const snapshot=JSON.stringify(drafts);say('Basisversionen mit OSM abgleichen …');
      try{
        const found=await checkVersions(JSON.parse(snapshot));
        if(snapshot!==JSON.stringify(drafts))throw Error('Entwürfe wurden geändert; Versionsprüfung wiederholen.');
        checkedFor=versions();conflicts=found;
        say(found.length?'Versionskonflikte: '+found.join(' ')+' Bitte in einem OSM-Editor abgleichen.':drafts.some(d=>d.base)?'Alle Basisversionen sind aktuell. Vor einem späteren Upload erneut prüfen.':'Nur neue Punkte: keine Basisversionen zu prüfen. Duplikate bitte manuell prüfen.');
      }catch(e){say(userError(e));}finally{setBusy(false);}
    });
    el('osmImport').addEventListener('change',async()=>{
      const file=el('osmImport').files[0];if(!file)return;
      if(!canSwitch()){el('osmImport').value='';return;}
      try{
        if(file.size>5*1024*1024)throw Error('Datei größer als 5 MB.');
        setBusy(true);
        const incoming=restore(await file.text()),merged=[...drafts,...incoming];
        if(dirty)throw Error('Offene Änderungen zuerst speichern oder verwerfen.');
        osc(merged);drafts=merged;say('Entwürfe ergänzt.'+persist());refresh();
      }catch(e){say(userError(e));}finally{setBusy(false);el('osmImport').value='';}
    });
    root.addEventListener?.('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
    document.addEventListener('keydown',e=>{
      if(e.key==='Escape'&&placing){cancel();say('Punktsetzen beendet.');}
      const view=el('osmEditView');
      if((e.ctrlKey||e.metaKey)&&(e.key||'').toLowerCase()==='s'&&current&&!view.hidden&&view.offsetParent!==null){e.preventDefault();if(!el('osmSave').disabled)save();}
    });

    setTab('find');renderForm();refresh();
    const api={
      startAt(point){if(!canSwitch())return;options.onStart?.();placing=true;place(point);},
      findNearby(point){if(!canSwitch())return;setTab('find');el('osmSearch').value='';nearbyPoint=point;search();status.focus?.();},
      enter(){
        viewActive=true;options.onStart?.();applyMode();
        // Deferred so an action that opens the view (context menu, hover) can claim the editor first.
        setTimeout(()=>{if(viewActive&&tab==='find'&&!busy&&!current&&(!candidates.length||movedAway()))search();},0);
      },
      leave(){viewActive=false;placing=false;applyMode();},
      load,cancel,render,setTab,mapClick,addPoint:mapClick,
      get active(){return mode()!==null;},
      get tab(){return tab;},
    };
    return api;
  }
  root.OSMEditor={tags,element,changes,validateDraft,osc,restore,checkVersions,wayShape,pickRadiusMeters,formatDistance,create};
})(typeof window==='undefined'?globalThis:window);
