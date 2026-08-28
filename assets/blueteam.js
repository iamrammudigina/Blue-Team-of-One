/* Blue Team of One — console theatre: ⌘K palette, copy buttons, terminal, progress */
(function(){
  "use strict";
  var reduce = window.matchMedia("(prefers-reduced-motion:reduce)").matches;

  /* ---------- scroll progress (posts) ---------- */
  var prog = document.getElementById("progress");
  if(prog){
    window.addEventListener("scroll",function(){
      var h=document.documentElement, max=h.scrollHeight-h.clientHeight;
      prog.style.width=(max>0?(h.scrollTop/max*100):0)+"%";
    },{passive:true});
  }

  /* ---------- copy buttons on code blocks ---------- */
  document.querySelectorAll("pre.code, pre").forEach(function(pre){
    if(pre.closest(".term")) return;
    var wrap=document.createElement("div"); wrap.className="codewrap";
    pre.parentNode.insertBefore(wrap,pre); wrap.appendChild(pre);
    var b=document.createElement("button"); b.className="copybtn"; b.textContent="Copy";
    wrap.appendChild(b);
    b.addEventListener("click",function(){
      var txt=pre.innerText.replace(/^PS>\s?/gm,"");
      if(navigator.clipboard) navigator.clipboard.writeText(txt);
      b.textContent="✓ Copied"; b.classList.add("done");
      setTimeout(function(){b.textContent="Copy"; b.classList.remove("done");},1400);
    });
  });

  /* ---------- homepage typing terminal ---------- */
  var logEl=document.getElementById("log");
  if(logEl){
    var lines=[
      '<span class="c1">PS BlueTeam:\\&gt;</span> <span class="cmd">Get-FieldNote</span> <span class="par">-Latest -Verified</span>',
      '',
      '<span class="hd">Id       Vertical   Status     Note</span>',
      '<span class="rule">──       ────────   ──────     ────</span>',
      '<span class="id">FN-027</span>   Identity   <span class="ok">Verified</span>   <span class="val">Real defensive work, written honestly.</span>'
    ];
    if(reduce){ logEl.innerHTML=lines.join("\n")+'<span class="cursor"></span>'; }
    else{
      var li=0;(function type(){
        if(li>=lines.length){ if(!logEl.querySelector(".cursor")) logEl.insertAdjacentHTML("beforeend",'<span class="cursor"></span>'); return; }
        logEl.insertAdjacentHTML("beforeend",(li?"\n":"")+lines[li]); li++;
        setTimeout(type, li===lines.length?520:520);
      })();
    }
  }

  /* ---------- ⌘K command palette (real search index) ---------- */
  var back=document.getElementById("palBack");
  if(!back) return;
  var input=document.getElementById("palInput"), list=document.getElementById("palList");
  var items=[], sel=0, shown=[];

  // static vertical shortcuts
  var VCODES={identity:"IDN",endpoint:"EDR",forensics:"DFIR",email:"MAIL",ir:"IR",detection:"DET",cloud:"CLD",soc:"SOC",powershell:"PS"};
  var verts=[
    ["identity","Identity Security"],["endpoint","Endpoint Security"],["forensics","Digital Forensics"],
    ["email","Email Security"],["ir","Incident Response"],["detection","Detection Engineering"],
    ["cloud","Cloud Security"],["soc","SOC Operations"],["powershell","PowerShell Library"]
  ].map(function(v){return {code:VCODES[v[0]],txt:v[1],k:"vertical",url:"/"+v[0]+"/"};});
  items=verts.slice();

  // real posts from the search index
  fetch("/assets/search-index.json").then(function(r){return r.json();}).then(function(docs){
    docs.forEach(function(d){
      var slug=(d.vertical||"").toLowerCase();
      var code=VCODES[slug]|| (d.vertical? d.vertical.slice(0,3).toUpperCase() : "FN");
      items.push({code:code, txt:d.title, k:"note", url:d.url});
    });
    if(back.classList.contains("open")) render(input.value);
  }).catch(function(){});

  function render(q){
    q=(q||"").toLowerCase().trim();
    shown = q ? items.filter(function(i){return (i.txt+" "+i.code+" "+i.k).toLowerCase().indexOf(q)>-1;}) : items;
    if(!shown.length){ list.innerHTML='<div class="empty">Get-FieldNote: no match for "'+q+'". Try TAP, KQL, PIM, Intune.</div>'; return; }
    if(sel>=shown.length) sel=shown.length-1; if(sel<0) sel=0;
    list.innerHTML=shown.map(function(i,ix){
      return '<a class="opt'+(ix===sel?" sel":"")+'" href="'+i.url+'" data-ix="'+ix+'"><span class="code">'+i.code+'</span><span class="txt">'+esc(i.txt)+'</span><span class="krow">'+i.k+'</span></a>';
    }).join("");
  }
  function esc(s){return (s||"").replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c];});}
  function open(){ back.classList.add("open"); input.value=""; sel=0; render(""); setTimeout(function(){input.focus();},30); }
  function close(){ back.classList.remove("open"); }
  function goSel(){ if(shown.length) window.location.href=shown[sel].url; }

  var openBtn=document.getElementById("openPal");
  if(openBtn) openBtn.addEventListener("click",open);
  input.addEventListener("input",function(){ sel=0; render(input.value); });
  back.addEventListener("click",function(e){ if(e.target===back) close(); });
  list.addEventListener("click",function(e){ var o=e.target.closest(".opt"); if(o){ e.preventDefault(); sel=+o.dataset.ix; goSel(); } });
  document.addEventListener("keydown",function(e){
    if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==="k"){ e.preventDefault(); back.classList.contains("open")?close():open(); return; }
    if(!back.classList.contains("open")) return;
    if(e.key==="Escape") close();
    else if(e.key==="ArrowDown"){ e.preventDefault(); sel=Math.min(sel+1,shown.length-1); render(input.value); }
    else if(e.key==="ArrowUp"){ e.preventDefault(); sel=Math.max(sel-1,0); render(input.value); }
    else if(e.key==="Enter"){ e.preventDefault(); goSel(); }
  });
})();
