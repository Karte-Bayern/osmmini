const {test}=require('node:test');
const assert=require('node:assert/strict');
require('../web/planning.js');
const P=PlanningTools;
const rectangle=(x,y,w,h,kind='site',floors=1)=>({kind,floors,name:'Entwurf',points:[[x,y],[x+w,y],[x+w,y+h],[x,y+h]]});
test('spherical distance, area, perimeter and floor estimate use metres',()=>{
 const shape=rectangle(0,0,0.001,0.001,'building',3), m=P.measure(shape);
 assert.ok(Math.abs(m.area_m2-12364.35)<0.1);
 assert.ok(Math.abs(m.length_m-444.78)<0.01);
 assert.equal(m.floor_area_m2,3*m.area_m2);
 assert.ok(Math.abs(P.measure({kind:'line',points:[[0,0],[0.001,0]]}).length_m-111.195)<0.001);
 assert.ok(Math.abs(P.measure({...shape,points:shape.points.toReversed()}).area_m2-m.area_m2)<1e-6);
});
test('invalid, self intersecting and degenerate drawings cannot be saved',()=>{
 for(const points of [[[0,0],[0.001,0.001],[0,0.001],[0.001,0]],[[0,0],[0,0],[0.001,0.001]],[[0,0],[0.001,0],[0.002,0]],[[0,0],[1,0],[1,1]],[[0,0],[NaN,0],[1,1]],[[0,86],[0.001,86],[0.001,86.001]]]) assert.throws(()=>P.measure({kind:'site',points}));
 assert.throws(()=>P.measure({...rectangle(12,48,.001,.001,'building'),floors:1.5}));
 assert.throws(()=>P.measure({...rectangle(12,48,.001,.001,'building'),floors:0}));
 assert.throws(()=>P.measure({kind:'toString',points:[[0,0],[0.001,0]]}));
});
test('dateline sketches keep small areas and contiguous exported rings',()=>{
 const shape={kind:'site',name:'Dateline',points:[[179.999,0],[-179.999,0],[-179.999,.001],[179.999,.001]]};
 assert.ok(Math.abs(P.measure(shape).area_m2-24728.69)<0.1);
 const ring=P.collection([shape]).features[0].geometry.coordinates[0];
 assert.deepEqual(ring[0],ring.at(-1));
 assert.ok(ring[1][0]-ring[0][0]<.003);
 const building={kind:'building',floors:2,points:[[179.9995,.0002],[-179.9995,.0002],[-179.9995,.0008],[179.9995,.0008]]};
 assert.equal(P.balance([shape,building]).warning,undefined);
});
test('balance only reports coverage for disjoint buildings strictly within a single site',()=>{
 const site=rectangle(12,48,.01,.01), a=rectangle(12.001,48.001,.001,.001,'building',2), b=rectangle(12.004,48.004,.001,.001,'building',3);
 const result=P.balance([site,a,b]);
 assert.equal(result.warning,undefined);
 assert.equal(result.count,2);
 assert.ok(result.coverage_percent>1.99&&result.coverage_percent<2.01);
 assert.equal(result.free_m2,result.site_m2-result.footprint_m2);
 assert.equal(result.floor_area_m2,P.measure(a).area_m2*2+P.measure(b).area_m2*3);
 for(const items of [[a],[site,site,a],[site,a,a],[site,a,rectangle(12.0012,48.0012,.0001,.0001,'building')],[site,rectangle(12.02,48.02,.001,.001,'building')],[site,rectangle(12,48,.001,.001,'building')]]) {
   const invalid=P.balance(items);assert.ok(invalid.warning);assert.equal(invalid.coverage_percent,undefined);
 }
});
test('concave reference areas reject edges crossing outside even if vertices are inside',()=>{
 const site={kind:'site',points:[[0,0],[.01,0],[.01,.01],[.006,.01],[.006,.004],[.004,.004],[.004,.01],[0,.01]]};
 const building=rectangle(.002,.006,.006,.002,'building');
 assert.match(P.balance([site,building]).warning,/innerhalb/);
});
test('saved drafts are validated and exports retain names, floors and measurement metadata',()=>{
 const item=rectangle(12,48,.001,.001,'building',4);
 const restored=P.restore(JSON.stringify({version:1,items:[item]}));
 assert.deepEqual(restored,[item]);
 const f=P.collection(restored).features[0];
 assert.equal(f.properties.floors,4);assert.equal(f.properties.name,'Entwurf');
 assert.equal(f.properties.floor_area_m2,f.properties.area_m2*4);
 assert.match(f.properties.measurement_model,/not survey/);
 for(const data of [{version:2,items:[]},{version:1,items:[{kind:'unknown'}]},{version:1,items:Array(101).fill(item)}]) assert.throws(()=>P.restore(JSON.stringify(data)));
});
test('drawing controller saves, reloads, cancels, deletes and rehydrates map layers',()=>{
 class Element {
   constructor(){this.value='';this.children=[];this.style={};this.listeners={};}
   append(...children){this.children.push(...children);} replaceChildren(){this.children=[];}
   setAttribute(){} addEventListener(event,fn){this.listeners[event]=fn;}
   click(){this.listeners.click?.();}
 }
 const elements={};global.document={getElementById:id=>elements[id]??=new Element(),createElement:()=>new Element(),addEventListener(){}};
 elements.planKind=new Element();elements.planKind.value='site';elements.planFloors=new Element();elements.planFloors.value='1';
 let stored=null,data=null,ready=true,starts=0;
 global.localStorage={getItem:()=>stored,setItem:(_,value)=>stored=value};
 const canvas={style:{}};
 const map={isStyleLoaded:()=>ready,getSource:()=>data?{setData:d=>data=d}:null,addSource:(_,s)=>data=s.data,addLayer(){},getCanvas:()=>canvas};
 const controller=P.create(map,{onStart:()=>starts++});
 elements.planStart.click();assert.equal(controller.active,true);assert.equal(starts,1);
 for(const [lng,lat] of [[12,48],[12.001,48],[12.001,48.001]]) controller.addPoint({lngLat:{lng,lat}});
 assert.equal(elements.planFinish.disabled,false);elements.planFinish.click();
 assert.equal(controller.active,false);assert.equal(data.features.length,1);assert.equal(P.restore(stored).length,1);
 data=null;ready=false;controller.render();assert.equal(data,null);ready=true;controller.render();assert.equal(data.features.length,1);
 elements.planStart.click();controller.addPoint({lngLat:{lng:12,lat:48}});controller.cancel();assert.equal(data.features.length,1);
 P.create(map);assert.equal(elements.planItems.children.length,1);
 elements.planItems.children[0].children.at(-1).click();assert.equal(P.restore(stored).length,0);assert.equal(data.features.length,0);
});
