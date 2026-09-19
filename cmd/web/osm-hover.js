/* Lightweight inspection of locally indexed OSM objects with live tag refresh. */
(function(root){
  'use strict';
  const SOURCE='osm-hover-object', LINE='osm-hover-line', FILL='osm-hover-fill', POINT='osm-hover-point';
  const empty=()=>({type:'FeatureCollection',features:[]});
  const text=(node,value)=>{node.textContent=String(value);return node;};
  function create(map){
    const el=id=>document.getElementById(id), button=el('osmHoverToggle'), info=el('osmHoverInfo');
    let enabled=false,timer=null,request=null,serial=0,current=null,cache=new Map();
    function setInfo(title,detail,tags,object){
      info.replaceChildren();info.hidden=false;
      const heading=document.createElement('strong');text(heading,title);info.append(heading);
      if(detail){const copy=document.createElement('span');text(copy,detail);info.append(copy);}
      if(tags&&Object.keys(tags).length){const list=document.createElement('dl');Object.entries(tags).sort(([a],[b])=>a.localeCompare(b)).slice(0,8).forEach(([key,value])=>{const dt=document.createElement('dt'),dd=document.createElement('dd');text(dt,key);text(dd,value);list.append(dt,dd);});info.append(list);}
      if(object){const actions=document.createElement('div');actions.className='osm-hover-actions';const edit=document.createElement('button'),open=document.createElement('a'),route=document.createElement('button');edit.type=route.type='button';edit.className=route.className=open.className='btn btn-ghost';edit.textContent='Bearbeiten';open.textContent='In OSM öffnen';route.textContent='Route hierher';open.href=`https://www.openstreetmap.org/${object.type}/${object.id}`;open.target='_blank';open.rel='noopener';edit.addEventListener('click',()=>root.dispatchEvent(new CustomEvent('osmmini:edit-object',{detail:object})));route.addEventListener('click',()=>root.dispatchEvent(new CustomEvent('osmmini:route-object',{detail:object})));actions.append(edit,open,route);info.append(actions);}
    }
    function clear(){
      current=null;if(request)request.abort();request=null;serial++;
      if(map.isStyleLoaded()&&map.getSource(SOURCE))map.getSource(SOURCE).setData(empty());
      info.hidden=true;info.replaceChildren();map.getCanvas().style.cursor='';
    }
    function render(){
      if(!map.isStyleLoaded())return;
      const data=current?.feature?{type:'FeatureCollection',features:[current.feature]}:empty();
      if(map.getSource(SOURCE)){map.getSource(SOURCE).setData(data);return;}
      map.addSource(SOURCE,{type:'geojson',data});
      map.addLayer({id:FILL,type:'fill',source:SOURCE,filter:['==','$type','Polygon'],paint:{'fill-color':'#2563eb','fill-opacity':.16}});
      map.addLayer({id:LINE,type:'line',source:SOURCE,filter:['!=','$type','Point'],paint:{'line-color':'#2563eb','line-width':4}});
      map.addLayer({id:POINT,type:'circle',source:SOURCE,filter:['==','$type','Point'],paint:{'circle-radius':9,'circle-color':'#2563eb','circle-opacity':.9,'circle-stroke-width':3,'circle-stroke-color':'#fff'}});
    }
    function featureFor(object,fallback){
      if(object.type==='node')return {type:'Feature',properties:{},geometry:{type:'Point',coordinates:[object.lon,object.lat]}};
      const nodes=new Map((object.elements||[]).filter(e=>e.type==='node').map(n=>[n.id,[n.lon,n.lat]]));
      const way=(object.elements||[]).find(e=>e.type==='way'&&e.id===object.id)||object;
      const coordinates=(way.nodes||[]).map(id=>nodes.get(id)).filter(Boolean);
      if(coordinates.length>1)return {type:'Feature',properties:{},geometry:{type:'LineString',coordinates}};
      return {type:'Feature',properties:{},geometry:{type:'Point',coordinates:fallback}};
    }
    async function inspect(feature,token){
      const type=feature.properties.kind==='node'?'node':'way',id=Number(feature.properties.osm_id),key=type+'/'+id;
      const fallback=feature.geometry.coordinates;
      setInfo(feature.properties.label||key,'Aktuellen OSM-Stand laden …');
      try{
        let object=cache.get(key);
        if(!object){
          request=new AbortController();
          const endpoint=`https://api.openstreetmap.org/api/0.6/${type}/${id}${type==='way'?'/full':''}.json`;
          const response=await fetch(endpoint,{signal:request.signal,credentials:'omit'});
          if(!response.ok)throw Error(response.status===404?'Objekt ist nicht mehr verfügbar.':`OSM-Abruf fehlgeschlagen (HTTP ${response.status}).`);
          const body=await response.json();object=(body.elements||[]).find(item=>item.type===type&&item.id===id);
          if(!object)throw Error('OSM hat kein passendes Objekt geliefert.');
          object.elements=body.elements;cache.set(key,object);
        }
        if(token!==serial||!enabled)return;
        current={feature:featureFor(object,fallback)};render();map.getCanvas().style.cursor='pointer';
        const name=object.tags?.name||feature.properties.label||key;
        setInfo(name,`${type==='node'?'Punkt':'Weg / Fläche'} ${id} · Version ${object.version??'–'} · aktueller OSM-Stand`,object.tags,{type,id,lat:fallback[1],lon:fallback[0],label:name});
      }catch(error){
        if(error.name==='AbortError'||token!==serial)return;
        current={feature:{type:'Feature',properties:{},geometry:{type:'Point',coordinates:fallback}}};render();
        setInfo(feature.properties.label||key,error.name==='TypeError'?'Keine Verbindung zu OSM.':'Lokaler Treffer · '+error.message);
      }finally{if(token===serial)request=null;}
    }
    async function lookup(event){
      const token=++serial,center=event.lngLat;
      if(request)request.abort();
      try{
        const params=new URLSearchParams({lat:center.lat,lon:((center.lng+180)%360+360)%360-180,radius_m:'45',limit:'30'});
        const response=await fetch('/api/v1/geo/pois?'+params,{signal:AbortSignal.timeout(8000)});
        if(!response.ok)throw Error('Lokaler Index nicht verfügbar.');
        const body=await response.json();if(token!==serial||!enabled)return;
        const candidates=body.features||[];
        if(!candidates.length){clear();return;}
        const nearest=candidates.map(feature=>({feature,distance:Math.hypot(map.project(feature.geometry.coordinates).x-event.point.x,map.project(feature.geometry.coordinates).y-event.point.y)})).sort((a,b)=>a.distance-b.distance)[0];
        if(!nearest||nearest.distance>22){clear();return;}
        await inspect(nearest.feature,token);
      }catch(error){if(error.name!=='AbortError'&&token===serial&&enabled)setInfo('Objektprüfung',error.name==='TypeError'?'Lokaler Index ist nicht erreichbar.':'Objekt konnte nicht bestimmt werden.');}
    }
    function onMove(event){if(!enabled)return;clearTimeout(timer);timer=setTimeout(()=>lookup(event),180);}
    button?.addEventListener('click',()=>{enabled=!enabled;button.setAttribute('aria-pressed',String(enabled));button.textContent=enabled?'Objektprüfung aktiv – über die Karte fahren':'Objekte unter dem Zeiger prüfen';if(enabled)setInfo('Objektprüfung aktiv','Fahre mit dem Zeiger über einen erfassten Ort auf der Karte.');else clear();});
    map.on('mousemove',onMove);map.on('mouseout',()=>{if(enabled){clearTimeout(timer);clear();}});
    return {render,clear,get enabled(){return enabled;}};
  }
  root.OSMHover={create};
})(typeof window==='undefined'?globalThis:window);
