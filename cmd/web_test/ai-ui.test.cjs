const {test}=require('node:test');
const assert=require('node:assert/strict');
require('../web/ai-ui.js');
test('drawing geometry rejects invalid coordinates and bounded circle sizes',()=>{
 for(const coordinates of [[],[[181,48]],[[12,NaN]],[[12,90]],[[12,'48']]]) assert.throws(()=>AIOutput.geometry({type:'marker',coordinates}));
 assert.throws(()=>AIOutput.geometry({type:'circle',coordinates:[[12,48]],radius_m:100001}));
 assert.throws(()=>AIOutput.geometry({type:'line',coordinates:[[12,48]]}));
 const circle=AIOutput.geometry({type:'circle',coordinates:[[12,48]],radius_m:1000});
 assert.equal(circle.coordinates[0].length,65);
 assert.ok(Math.abs(circle.coordinates[0][0][1]-48-1000/6371008.8*180/Math.PI)<1e-9);
});
test('map objects survive style reload and are individually removable; buttons require click',()=>{
 class Element {constructor(){this.children=[];this.style={};}appendChild(e){this.children.push(e);}append(...es){this.children.push(...es);}addEventListener(_,fn){this.click=fn;}}
 global.document={createElement:()=>new Element()};
 let data,ready=true;const handlers={},sent=[];
 const map={isStyleLoaded:()=>ready,on:(event,fn)=>handlers[event]=fn,getSource:()=>data?{setData:d=>data=d}:null,addSource:(_,s)=>data=s.data,addLayer(){},fitBounds(){}};
 const output=AIOutput.create(map,p=>sent.push(p)),parent=new Element();
 output.render(parent,[{type:'arrow',coordinates:[[12,48],[12.1,48.1]]},{type:'button',label:'Details',prompt:'Mehr Details'}]);
 assert.equal(data.features.length,2);
 assert.equal(sent.length,0);
 parent.children[1].children[1].click();assert.deepEqual(sent,['Mehr Details']);
 data=null;handlers['style.load']();assert.equal(data.features.length,2);
 parent.children[0].children.at(-1).click();assert.equal(data.features.length,0);
 output.render(parent,[{type:'card',text:'<script>bad()</script>'}]);
 assert.equal(parent.children.at(-1).children[1].textContent,'<script>bad()</script>');
 output.clear();assert.equal(data.features.length,0);
});
