// Generates conformance fixtures by executing the unmodified AMLL algorithms.
// Usage: node scripts/amll/generate-reference.mjs /path/to/applemusic-like-lyrics
// No npm packages, browser, or network access are needed (Node 22+).
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
const root = resolve(process.argv[2]);
const source = name => readFileSync(`${root}/packages/core/src/${name}`, 'utf8');
const time = source('utils/time.ts');
async function load(name, withTime = true) {
  let code = source(name).replace(/import[^;]+;/g, '');
  code = stripTypeScriptTypes((withTime ? time : '') + '\n' + code, { mode: 'strip' });
  return import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
}
const { TimelineController } = await load('lyric-player/base/timeline.ts');
const { SeekDetector } = await load('lyric-player/base/seek-detector.ts');
const { getPosYSpringPolicy } = await load('lyric-player/base/spring.ts', false);
const scenarios = [
  [[0,1000],[3000,4000]],
  [[153305,157180],[154743,156466],[156154,160218],[160268,162974]],
  [[0,10000],[1000,2000],[18000,19000]],
  [[8000,10000],[11000,12000],[20000,23000]],
  [[0,60000],[10000,12000],[68000,73000]],
  [[0,1000],[0,3000],[3000,4500]],
];
let seed = 6719;
const random = max => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % max; };
const timelines = scenarios.map(bounds => {
  const controller = new TimelineController();
  controller.setTimeBounds(bounds.map(([startTime, endTime]) => ({ startTime, endTime })));
  const end = Math.max(...bounds.map(x => x[1]));
  const times = [0, ...new Set(bounds.flatMap(([a,b]) => [Math.max(0,a-1),a,a+1,b-1,b,b+1]))].sort((a,b)=>a-b);
  const inputs = times.map(time => ({time, seek:false}));
  for (let i=0;i<60;i++) inputs.push({time:random(end+10000), seek:i%3===0});
  const frames = inputs.map(({time,seek}) => {
    controller.sync(time, seek);
    const s = controller.getSnapshot();
    return {time, seek, playing:[...s.playingGroups].sort((a,b)=>a-b), highlighted:[...s.highlightedGroups].sort((a,b)=>a-b),
      scroll:s.scrollToIndex, ended:s.isEndOfSong, gap:s.activeInterlude ?
      [s.activeInterlude.startTime,s.activeInterlude.endTime,s.activeInterlude.anchorLineIndex] : null};
  });
  return {bounds, frames};
});
let wall=0;
const detector=new SeekDetector(()=>wall);
const seeks=[];
let media=0;
for(let i=0;i<180;i++) {
  const delta=i%31===0?10000:16;
  wall+=delta; media+=i%19===0?-900:i%23===0?2000:16;
  const playing=i%11!==0;
  seeks.push({media,wall,playing,expected:detector.detect(media,playing)});
}
const springs=[-100,0,100,300,799,800,4000].map(interval=>({interval,...getPosYSpringPolicy(false,false,interval)}));
const upstream = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim();
const output={upstream,timelines,seeks,springs};
writeFileSync('CassetteTests/Fixtures/amll-reference.json', JSON.stringify(output));
console.log(`Generated ${timelines.reduce((n,s)=>n+s.frames.length,0)} timeline, ${seeks.length} seek and ${springs.length} spring samples.`);
