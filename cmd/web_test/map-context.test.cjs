const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');
require('../web/map-context.js');
function setup(){
 const timers=new Map();let seq=0;const original={setTimeout:global.setTimeout,clearTimeout:global.clearTimeout,addEventListener:global.addEventListener};
 global.setTimeout=fn=>{timers.set(++seq,fn);return seq;};global.clearTimeout=id=>timers.delete(id);global.addEventListener=()=>{};global.innerWidth=400;global.innerHeight=600;
 class El{
  constructor(){this.children=[];this.handlers={};this.style={};this.offsetWidth=250;this.offsetHeight=320;this.attrs={};}
  append(...es){this.children.push(...es);}setAttribute(k,v){this.attrs[k]=v;}contains(e){return e===this||this.children.includes(e);}closest(){return null;}
  addEventListener(e,fn){this.handlers[e]=fn;}focus(){document.activeElement=this;}getBoundingClientRect(){return {left:20,top:30};}
 }
 const body=new El(),container=new El(),canvas=new El(),mapHandlers={},chosen=[];
 global.document={body,activeElement:canvas,createElement:()=>new El(),addEventListener(){}};
 const map={getContainer:()=>container,getCanvas:()=>canvas,unproject:([x,y])=>({lng:x/10,lat:y/10}),project:()=>({x:100,y:100}),getCenter:()=>({lng:12,lat:48}),on:(event,fn)=>mapHandlers[event]=fn};
 const api=MapContext.create(map,[{label:'Marker',run:p=>chosen.push(p)},{label:'Route',run:p=>chosen.push(p)}]);
 const menu=body.children[0];
 function event(props={}){return {target:canvas,clientX:120,clientY:130,pointerId:1,pointerType:'touch',preventDefault(){this.prevented=true;},stopPropagation(){},stopImmediatePropagation(){this.stopped=true;},...props};}
 return {container,canvas,menu,api,chosen,mapHandlers,timers,event,restore(){Object.assign(global,original);}};
}
test('right click opens a clamped keyboard menu and uses the clicked coordinates',()=>{
 const h=setup();try{
  const e=h.event();h.container.handlers.contextmenu(e);assert.equal(e.prevented,true);assert.equal(h.menu.hidden,false);assert.equal(document.activeElement,h.menu.children[1]);
  h.menu.handlers.keydown(h.event({key:'ArrowDown'}));assert.equal(document.activeElement,h.menu.children[2]);
  h.menu.children[2].handlers.click();assert.deepEqual(h.chosen,[{lng:10,lat:10}]);assert.equal(h.menu.hidden,true);
  h.api.openAt(390,590);assert.equal(h.menu.style.left,'142px');assert.equal(h.menu.style.top,'272px');
  h.menu.handlers.keydown(h.event({key:'Escape'}));assert.equal(h.menu.hidden,true);assert.equal(document.activeElement,h.canvas);
  h.canvas.handlers.keydown(h.event({key:'F10',shiftKey:true}));h.menu.children[1].handlers.click();assert.deepEqual(h.chosen.at(-1),{lng:12,lat:48});
 }finally{h.restore();}
});
test('long press cancels for movement and multitouch, opens when held and suppresses the following click',()=>{
 const h=setup();try{
  h.container.handlers.pointerdown(h.event());h.container.handlers.pointermove(h.event({clientX:150}));assert.equal(h.timers.size,0);
  h.container.handlers.pointerup(h.event());h.container.handlers.pointerdown(h.event());h.container.handlers.pointerdown(h.event({pointerId:2}));assert.equal(h.timers.size,0);
  h.container.handlers.pointerup(h.event());h.container.handlers.pointerup(h.event({pointerId:2}));
  h.container.handlers.pointerdown(h.event());[...h.timers.values()][0]();assert.equal(h.menu.hidden,false);
  h.container.handlers.pointerup(h.event());const click=h.event();h.container.handlers.click(click);assert.equal(click.stopped,true);assert.equal(h.chosen.length,0);
 }finally{h.restore();}
});
test('ordinary left click never creates markers; explicit drawing modes still receive clicks',()=>{
 const src=fs.readFileSync(require.resolve('../web/app.js'),'utf8');let callback,count=0;
 const segment=src.slice(src.indexOf("map.on('click', ev=>{"),src.indexOf('restoreCustomMarkers();'));
 const context=vm.createContext({map:{on:(_,cb)=>callback=cb},window:{},gisMeasureActive:false,addGISMeasurePoint:()=>count++});
 vm.runInContext(segment,context);callback({});assert.equal(count,0);
 context.gisMeasureActive=true;callback({});assert.equal(count,1);
 context.window.osmEditor={active:true,addPoint:()=>count+=10};callback({});assert.equal(count,11);
 assert.ok(!src.includes("deleteStopMarker(id);\n  });\n  return s;"));
});
