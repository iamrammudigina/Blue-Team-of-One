#!/usr/bin/env node
/* Ground Truth builder — regenerates section post-lists, vertical index counts,
   the home "recent" list, and assets/search-index.json from each post's
   <script id="gt-meta"> block. Run from repo root:  node build.mjs
   Idempotent. Empty sections and custom badges (e.g. "Series · 3 parts") are left as-is. */
import { readFileSync as R, writeFileSync as W, readdirSync as LS, existsSync as EX } from 'node:fs';
const ROOT=process.argv[2]||'.';
const VERTS=['soc','ir','identity','endpoint','email','detection','cloud','forensics','powershell'];
const CAT={soc:'SOC',ir:'IR',identity:'IDENTITY',endpoint:'ENDPOINT',email:'EMAIL',
  detection:'DETECTION',cloud:'CLOUD',forensics:'FORENSICS',powershell:'PS'};
// labels for NEW posts (existing posts carry their own baked vlabel/slabel)
const VLABEL={soc:'SOC Operations',ir:'Incident Response',identity:'Identity Security',
  endpoint:'Endpoint Security',email:'Email Security',detection:'Detection Engineering',
  cloud:'Cloud Security',forensics:'Digital Forensics',powershell:'PowerShell Library'};
const SLABEL={triage:'Alert triage',automation:'SOC automation',bec:'Business email compromise',
  scams:'Scams & social engineering',containment:'Containment & recovery','token-session':'Token & session security',
  'conditional-access':'Conditional Access','auth-mfa':'Authentication & MFA','privileged-access':'Privileged access',
  'identity-threat-detection':'Identity threat detection',threats:'Threats & remediation',hardening:'Hardening & compliance',
  delivery:'Delivery & mail flow',inbound:'Inbound security','access-delegation':'Mailbox access & delegation',
  outbound:'Outbound security','kql-library':'KQL Library','data-connectors':'Data connectors & ingestion',
  'sentinel-platform':'Sentinel, end to end','kql-hunting':'Advanced hunting (KQL)','sentinel-rules':'Sentinel & analytics rules',
  'tuning-noise':'Alert tuning & noise',correlation:'Correlation',sse:'Secure access (SSE)',posture:'Cloud posture',
  'purview-governance':'Purview & governance','litigation-holds':'Litigation holds','ediscovery-hard-cases':'eDiscovery hard cases',
  'onedrive-preservation':'OneDrive & SharePoint preservation','hold-release':'Hold verification & release',
  'hold-incidents':'Incidents caused by holds','runbook-mailbox-holds':'Exchange mailbox holds & lifecycle',
  'identity-access':'Identity & access','endpoint-intune':'Endpoint & Intune','detection-reporting':'Detection & reporting'};
const MO=['January','February','March','April','May','June','July','August','September','October','November','December'];
const SH=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const lDate=s=>{const[y,m,d]=s.split('-').map(Number);return `${MO[m-1]} ${d}, ${y}`;};
const sDate=s=>{const[,m,d]=s.split('-').map(Number);return `${SH[m-1]} ${d}`;};

const posts=[];
for(const fn of LS(`${ROOT}/posts`)){
  if(!fn.endsWith('.html')||fn.startsWith('_'))continue;
  const m=R(`${ROOT}/posts/${fn}`,'utf8').match(/<script type="application\/json" id="gt-meta">([\s\S]*?)<\/script>/);
  if(!m)continue;
  const p=JSON.parse(m[1]); p.slug=fn.slice(0,-5); p.url=`/posts/${p.slug}.html`; posts.push(p);
}
// section lists: preserve per-section manual order (ord desc). home: global date desc, ord as tiebreak.
const cmp=(a,b)=>(b.ord??1e9)-(a.ord??1e9)||(a.date<b.date?1:a.date>b.date?-1:0)||(a.slug<b.slug?-1:1);
const cmpDate=(a,b)=>(a.date<b.date?1:a.date>b.date?-1:0)||(b.ord??-1)-(a.ord??-1)||(a.slug<b.slug?-1:1);

const prow=p=>`      <a class="prow" href="${p.url}">
        <div class="meta"><span class="fmt ${p.fmtc||'deep'}">${p.fmt}</span><span class="date">${lDate(p.date)}</span></div>
        <h3>${p.title}</h3>
        <p>${p.teaser}</p>
        <span class="more">Read →</span>
      </a>`;

// section post-lists (only sections that have posts; empty sections untouched)
const countBy={}; let secN=0;
for(const v of VERTS){ if(!EX(`${ROOT}/${v}`))continue;
  for(const fn of LS(`${ROOT}/${v}`)){
    if(!fn.endsWith('.html')||fn==='index.html')continue;
    const sect=fn.slice(0,-5), file=`${ROOT}/${v}/${fn}`;
    const mine=posts.filter(p=>p.vertical===v&&p.section===sect).sort(cmp);
    countBy[`${v}/${sect}`]=mine.length;
    if(!mine.length)continue;
    let h=R(file,'utf8');
    const block=`<div class="plist">\n`+mine.map(prow).join('\n')+`\n    </div>`;
    const out=h.replace(/<div class="plist">[\s\S]*?<\/div>(?=\n  <\/div>\n<\/main>)/,block);
    if(out!==h){W(file,out);secN++;}
  }
}
// vertical index count badges — only touch standard "N post(s)" / "Coming soon"
let idxN=0;
for(const v of VERTS){ const file=`${ROOT}/${v}/index.html`; if(!EX(file))continue;
  let h=R(file,'utf8'),chg=false;
  h=h.replace(/(<a class="scard" href="\/([a-z]+)\/([a-z0-9-]+)\.html">\s*<span class="count-badge)( live)?(">)([^<]*)(<\/span>)/g,
    (m,pre,vv,ss,live,gt,txt,close)=>{
      if(!/^(\d+ posts?|Coming soon)$/.test(txt))return m;           // preserve custom badges
      const n=countBy[`${vv}/${ss}`]??0;
      chg=true;
      return pre+(n===0?`">Coming soon`:` live">${n} post${n===1?'':'s'}`)+close;
    });
  if(chg){W(file,h);idxN++;}
}
// home recent
const rrow=p=>`    <a class="rrow" href="${p.url}"><span class="cat">${CAT[p.vertical]}</span><span class="rt">${p.title}</span><span class="dt">${sDate(p.date)}</span></a>`;
{ const file=`${ROOT}/index.html`; let h=R(file,'utf8');
  const rows=[...posts].sort(cmpDate).slice(0,5).map(rrow).join('\n');
  const out=h.replace(/<div class="recent">[\s\S]*?<\/div>(?=\n<\/section>)/,`<div class="recent">\n${rows}\n  </div>`);
  if(out!==h)W(file,out);
}
// search-index
const extras=EX(`${ROOT}/assets/search-extra.json`)?JSON.parse(R(`${ROOT}/assets/search-extra.json`,'utf8')):[];
const rows=[...posts.map(p=>({sord:p.sord??-1,entry:{url:p.url,title:p.stitle??p.title,
  excerpt:p.excerpt??p.teaser,vertical:p.vlabel??VLABEL[p.vertical],section:p.slabel??SLABEL[p.section],text:p.text??''}})),...extras];
rows.sort((a,b)=>a.sord-b.sord);
W(`${ROOT}/assets/search-index.json`,JSON.stringify(rows.map(r=>r.entry),null,1));
console.log(`posts:${posts.length} sections:${secN} indexes:${idxN} search:${rows.length}`);
