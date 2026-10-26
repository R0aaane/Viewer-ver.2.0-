const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/performance_diagnostics.js','utf8');
const bootstrap = fs.readFileSync('web/index.html','utf8').match(/<script>\s*(function startFlutter[\s\S]*?)<\/script>/)[1];
vm.runInNewContext(source,{window:{location:{search:''}},URLSearchParams});
let now=0, sequence=0;
const timers=new Map(),frames=new Map();
function element(tag){return {tag,style:{},children:[],events:{},textContent:'',value:'',append(...items){this.children.push(...items)},appendChild(item){this.children.push(item)},setAttribute(){},addEventListener(name,fn){this.events[name]=fn},remove(){this.removed=true}}}
const body=element('body');
const document={body,baseURI:'http://example.test/',hidden:false,createElement:element,addEventListener(){}};
const context={console:{warn(){},error(){}},window:{location:{search:'?perf=1',href:'http://example.test/?perf=1'},devicePixelRatio:3,innerWidth:390,innerHeight:844},document,navigator:{userAgent:'iPhone AppleWebKit Safari'},URLSearchParams,URL,AbortController,
performance:{now:()=>now,getEntriesByType:()=>[
 {name:'http://example.test/media/private-id/thumb?token=private',startTime:1,responseEnd:95,duration:94},
 {name:'https://fonts.example.test/public.woff2',startTime:1,responseEnd:95,duration:94}]},
fetch:async url=>({ok:true,json:async()=>({version:'test'}),arrayBuffer:async()=>new ArrayBuffer(0)}),
requestAnimationFrame:fn=>{frames.set(++sequence,fn);return sequence},cancelAnimationFrame:id=>frames.delete(id),
setTimeout:(fn,delay)=>{timers.set(++sequence,{fn,delay});return sequence},clearTimeout:id=>timers.delete(id)};
vm.runInNewContext(source,context);
const originalWarn=context.console.warn;
context.console.warn('WARNING: Falling back to CPU-only rendering. Reason: failed to create GrContext. http://example.test/private?token=private');
for(const search of ['', '?perf=1']) {
 for(const event of ['onload','onerror']) {
  const testBody=element('body');
  vm.runInNewContext(bootstrap,{window:{location:{search}},URLSearchParams,document:{body:testBody,createElement:element}});
  if(!search) assert.equal(testBody.children[0].src,'flutter_bootstrap.js');
  else {
   assert.equal(testBody.children.length,1);
   assert.equal(testBody.children[0].src,'performance_diagnostics.js');
   testBody.children[0][event]();
   assert.equal(testBody.children[1].src,'flutter_bootstrap.js');
  }
 }
}
(async()=>{
 await new Promise(resolve=>setImmediate(resolve));
 const panel=body.children[0], button=panel.children[1],output=panel.children[3];
 assert.equal(button.textContent,'計測開始');
 button.events.click();
 function frame(time){now=time;const [id,callback]=frames.entries().next().value;frames.delete(id);callback(time)}
 frame(0);frame(16);frame(96);
 await new Promise(resolve=>setImmediate(resolve));
 button.events.click();
 const result=JSON.parse(output.value);
 assert.equal(result.frames.count,2);
 assert.equal(result.framesOver50Ms,1);
 assert.equal(result.frames.maxMs,80);
 assert.equal(result.longTasksSupported,false);
 assert.equal(result.resources.thumbnail.count,1);
 assert.equal(result.resources.font.count,1);
 assert.equal(result.rendererSignals.cpuFallbackWarnings,1);
 assert.equal(result.rendererSignals.graphicsWarnings,1);
 assert.equal(result.health.count,1);
 assert.equal(output.value.includes('private'),false);
 assert.equal(frames.size,0);
 assert.equal(timers.size,0);
 panel.children[2].events.click();
 assert.notEqual(context.console.warn,originalWarn);
 assert.equal(panel.removed,true);
 console.log('PASS: default URL is inert; active diagnostics collect frames/API timings, redact URLs, and release timers');
})().catch(error=>{console.error(error);process.exitCode=1});
