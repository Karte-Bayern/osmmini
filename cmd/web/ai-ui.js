/* Structured AI output: data only, no executable markup from model responses. */
(function (root) {
  'use strict';
  const color = value => /^#[0-9a-f]{6}$/i.test(value || '') ? value : '#2563eb';
  function geometry(item) {
    const points = item.coordinates;
    if (!Array.isArray(points) || !points.length || points.length > 500 || !points.every(p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 85)) throw Error('Ungültige Koordinaten');
    if (item.type === 'marker') return {type:'Point',coordinates:points[0]};
    if (item.type === 'circle') {
      if (!Number.isFinite(item.radius_m) || item.radius_m < 1 || item.radius_m > 100000) throw Error('Kreisradius muss zwischen 1 und 100000 m liegen');
      const [lon,lat] = points[0].map(v=>v*Math.PI/180), d=item.radius_m/6371008.8;
      const ring=Array.from({length:65},(_,i)=>{
        const bearing=i/64*2*Math.PI;
        const y=Math.asin(Math.sin(lat)*Math.cos(d)+Math.cos(lat)*Math.sin(d)*Math.cos(bearing));
        const x=lon+Math.atan2(Math.sin(bearing)*Math.sin(d)*Math.cos(lat),Math.cos(d)-Math.sin(lat)*Math.sin(y));
        return [((x*180/Math.PI+540)%360)-180,y*180/Math.PI];
      });
      return {type:'Polygon',coordinates:[ring]};
    }
    if (item.type === 'polygon') {
      if(points.length<3) throw Error('Ein Gebiet benötigt mindestens drei Punkte');
      return {type:'Polygon',coordinates:[[...points,points[0]]]};
    }
    if (!['line','arrow'].includes(item.type) || points.length<2) throw Error('Eine Linie benötigt mindestens zwei Punkte');
    return {type:'LineString',coordinates:points};
  }
  function create(map, send) {
    const features=new Map(); let sequence=0;
    const source='ai-drawings';
    function sync(styleReady = false) {
      if(!styleReady && !map.isStyleLoaded()) return;
      const data={type:'FeatureCollection',features:[...features.values()]};
      if(map.getSource(source)) map.getSource(source).setData(data);
      else {
        map.addSource(source,{type:'geojson',data});
        map.addLayer({id:source+'-fill',type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':['get','color'],'fill-opacity':0.15}});
        map.addLayer({id:source+'-line',type:'line',source,filter:['!=',['geometry-type'],'Point'],paint:{'line-color':['get','color'],'line-width':3}});
        map.addLayer({id:source+'-point',type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-color':['get','color'],'circle-radius':7,'circle-stroke-color':'#ffffff','circle-stroke-width':2}});
      }
    }
    map.on('style.load',()=>sync(true));
    function button(parent,label,action) {const b=document.createElement('button');b.type='button';b.textContent=label;b.addEventListener('click',action);parent.appendChild(b);return b;}
    function render(parent, items) {
      if(!Array.isArray(items)) return;
      for(const item of items.slice(0,20)) {
        const box=document.createElement('section');box.className='ai-output';parent.appendChild(box);
        try {
          if(!item || typeof item!=='object') throw Error('Ungültiges Element');
          const title=document.createElement('strong');title.textContent=String(item.label||'KI-Ausgabe').slice(0,200);box.appendChild(title);
          if(item.type==='button') {
            if(typeof item.prompt!=='string'||!item.prompt.trim()||item.prompt.length>2000) throw Error('Ungültige Button-Aktion');
            button(box,item.label||'Anfragen',()=>send(item.prompt));
          } else if(item.type==='card') {
            const text=document.createElement('p');text.textContent=String(item.text||'').slice(0,5000);box.appendChild(text);
          } else if(item.type==='chart') {
            if(!Array.isArray(item.values)||!item.values.length||item.values.length>30||!item.values.every(v=>v&&Number.isFinite(v.value)&&v.value>=0)) throw Error('Diagramm benötigt 1–30 nichtnegative Werte');
            const max=Math.max(...item.values.map(v=>v.value),1);
            for(const v of item.values){const row=document.createElement('div');row.className='ai-chart-row';const label=document.createElement('span');label.textContent=`${String(v.label).slice(0,100)}: ${v.value} ${String(item.unit||'').slice(0,30)}`;const bar=document.createElement('div');bar.className='ai-chart-bar';bar.style.width=`${v.value/max*100}%`;row.append(label,bar);box.appendChild(row);}
          } else {
            if(features.size + (item.type === 'arrow' ? 2 : 1) > 200) throw Error('Zeichenlimit erreicht. Bitte zuerst Objekte entfernen.');
            const g=geometry(item), id=String(++sequence), ids=[id];
            features.set(id,{type:'Feature',id,properties:{color:color(item.color)},geometry:g});
            // Arrowhead is a local projected triangle at the end, scaled to the final segment.
            if(item.type==='arrow') {
              const ps=item.coordinates, a=ps.at(-2), b=ps.at(-1), c=Math.cos(b[1]*Math.PI/180), dx=(b[0]-a[0])*c,dy=b[1]-a[1],length=Math.hypot(dx,dy);
              if(length>0){const size=Math.min(length*0.18,0.01),ux=dx/length,uy=dy/length;const ring=[b,[b[0]-(ux+uy*0.5)*size/c,b[1]-(uy-ux*0.5)*size],[b[0]-(ux-uy*0.5)*size/c,b[1]-(uy+ux*0.5)*size],b];const head=id+'-head';ids.push(head);features.set(head,{type:'Feature',properties:{color:color(item.color)},geometry:{type:'Polygon',coordinates:[ring]}});}
            }
            sync();
            const status=document.createElement('p');status.textContent='Auf der Karte eingezeichnet';box.appendChild(status);
            const focus=button(box,'Auf Karte zeigen',()=>{const ps=g.type==='Point'?[g.coordinates]:g.type==='Polygon'?g.coordinates[0]:g.coordinates;const xs=ps.map(p=>p[0]),ys=ps.map(p=>p[1]);map.fitBounds([[Math.min(...xs),Math.min(...ys)],[Math.max(...xs),Math.max(...ys)]],{padding:60,maxZoom:15});});
            const remove=button(box,'Entfernen',()=>{ids.forEach(id=>features.delete(id));sync();status.textContent='Entfernt';focus.disabled=true;remove.disabled=true;});
          }
        } catch(error) {const text=document.createElement('p');text.textContent='Ausgabe nicht ausgeführt: '+error.message;box.appendChild(text);}
      }
    }
    return {render,clear(){features.clear();sync();}};
  }
  root.AIOutput={create,geometry};
})(typeof window==='undefined'?globalThis:window);
