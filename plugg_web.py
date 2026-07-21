#!/usr/bin/env python3
# =============================================================================
#  PLUGG · plugg_web.py — Flask backend for the browser UI    by @archnexus707
#  Reuses launcher.sh as the engine (single source of truth). Reads via the
#  headless JSON API; mutates via privileged subcommands. Open access (no auth).
# =============================================================================
import os, re, json, subprocess
from flask import Flask, request, Response, jsonify

HERE        = os.path.dirname(os.path.abspath(__file__))
LAUNCHER    = os.environ.get("PLUGG_LAUNCHER", os.path.join(HERE, "launcher.sh"))
CONF        = os.path.join(HERE, "plugg.conf")
PROFILE_DIR = os.path.join(HERE, "profiles")
PORT        = int(os.environ.get("PLUGG_PORT", "8088"))

app = Flask(__name__)

# ------------------------------------------------------------------ engine ---
def engine(*args, timeout=90):
    env = dict(os.environ, PLUGG_HEADLESS="1")
    try:
        p = subprocess.run([LAUNCHER, *args], capture_output=True, text=True,
                           env=env, timeout=timeout)
        return p.stdout, p.returncode
    except subprocess.TimeoutExpired:
        return "", 124

def engine_json(*args):
    out, _ = engine(*args)
    out = out.strip()
    # tolerate any stray log lines: grab the last JSON-looking line
    for line in reversed(out.splitlines()):
        line = line.strip()
        if line.startswith("{") or line.startswith("["):
            try: return json.loads(line)
            except Exception: pass
    return {}

# -------------------------------------------------- open access (no auth) ----
# The web UI is intentionally open — anyone who can reach the port can use it
# (fine on a private/event network you control).
@app.after_request
def no_cache(resp):
    # never let the browser serve a stale copy of the SPA / API
    resp.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    return resp

# --------------------------------------------------------------- API routes --
@app.get("/api/status")
def api_status():
    return Response(json.dumps(engine_json("status-json")), mimetype="application/json")

@app.get("/api/detect")
def api_detect():
    return Response(json.dumps(engine_json("detect-json")), mimetype="application/json")

@app.get("/api/profiles")
def api_profiles():
    return Response(json.dumps(engine_json("profiles-json")), mimetype="application/json")

@app.post("/api/config")
def api_config():
    d = request.get_json(force=True, silent=True) or {}
    def s(k, default=""): return str(d.get(k, default))
    band5 = str(d.get("band", "2.4")) == "5"
    ssid = s("ssid", "PLUGG_NET").strip() or "PLUGG_NET"
    pw   = s("pass", "Plugg12345")
    if len(pw) < 8:
        return jsonify({"ok": False, "error": "password must be >= 8 chars"}), 400
    det = engine_json("detect-json")
    up  = s("upstream") or det.get("upstream", {}).get("iface", "")
    ap  = s("apiface")  or det.get("ap", {}).get("iface", "")
    conf = {
        "SSID": ssid, "PASS": pw, "UPSTREAM": up, "APIFACE": ap,
        "SUBNET": s("subnet", "10.42.0"),
        "CHANNEL": "36" if band5 else "6",
        "BAND": "a" if band5 else "bg",
        "HW": "a" if band5 else "g",
        "WPA_MODE": s("wpa_mode", "2"),
        "ISOLATE": "yes" if d.get("isolate", True) else "no",
        "AUTOCHAN": "yes" if d.get("autochan", True) else "no",
        "WATCHDOG": "yes" if d.get("watchdog", True) else "no",
        "MAXSTA": s("maxsta", "0") or "0",
        "OFFMINS": s("offmins", "0") or "0",
        "COUNTRY": s("country", "US") or "US",
    }
    with open(CONF, "w") as f:
        for k, v in conf.items():
            f.write(f'{k}="{v}"\n')
    return jsonify({"ok": True, "applied": conf})

@app.post("/api/start")
def api_start():
    _, rc = engine("up", timeout=120)
    return jsonify({"ok": rc == 0, "status": engine_json("status-json")})

@app.post("/api/stop")
def api_stop():
    engine("down")
    return jsonify({"ok": True})

@app.post("/api/kick")
def api_kick():
    mac = (request.get_json(force=True, silent=True) or {}).get("mac", "")
    if not re.fullmatch(r"[0-9a-fA-F:]{17}", mac or ""):
        return jsonify({"ok": False, "error": "bad mac"}), 400
    return Response(json.dumps(engine_json("kick", mac)), mimetype="application/json")

@app.post("/api/unban")
def api_unban():
    return Response(json.dumps(engine_json("unban")), mimetype="application/json")

@app.post("/api/profile")
def api_profile_load():
    name = (request.get_json(force=True, silent=True) or {}).get("name", "")
    if not re.fullmatch(r"[\w.\- ]{1,40}", name or ""):
        return jsonify({"ok": False}), 400
    return Response(json.dumps(engine_json("apply-profile", name)), mimetype="application/json")

@app.post("/api/profile/save")
def api_profile_save():
    import shutil
    name = ((request.get_json(force=True, silent=True) or {}).get("name", "") or "").strip()
    if not re.fullmatch(r"[\w.\- ]{1,40}", name):
        return jsonify({"ok": False, "error": "name: letters/numbers/-/_ only"}), 400
    if not os.path.exists(CONF):
        return jsonify({"ok": False, "error": "configure the hotspot first"}), 400
    os.makedirs(PROFILE_DIR, exist_ok=True)
    safe = name.replace(" ", "_")
    shutil.copyfile(CONF, os.path.join(PROFILE_DIR, safe + ".conf"))
    return jsonify({"ok": True, "name": safe, "profiles": engine_json("profiles-json")})

@app.post("/api/gen-pass")
def api_gen_pass():
    import secrets, string
    alpha = string.ascii_letters + string.digits
    return jsonify({"pass": "".join(secrets.choice(alpha) for _ in range(14))})

@app.get("/api/qr.png")
def api_qr():
    st = engine_json("status-json")
    ssid = st.get("ssid", ""); pw = st.get("pass", "")
    def esc(x): return re.sub(r'([\\;,:"])', r'\\\1', str(x))
    payload = f"WIFI:T:WPA;S:{esc(ssid)};P:{esc(pw)};;"
    try:
        png = subprocess.run(["qrencode", "-o", "-", "-t", "PNG", "-s", "6", "-m", "2", payload],
                             capture_output=True, timeout=10).stdout
        return Response(png, mimetype="image/png")
    except Exception:
        return Response(b"", mimetype="image/png", status=404)

@app.get("/api/whoami")
def api_whoami():
    return jsonify({"ok": True})

# --------------------------------------------------------------- the SPA -----
@app.get("/")
def index():
    return Response(INDEX_HTML, mimetype="text/html")

INDEX_HTML = r"""<!doctype html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>PLUGG · the wifi plug</title>
<style>
:root{--bg:#0a0a12;--card:#12121f;--card2:#181828;--line:#262640;--tx:#e8e8f0;--mut:#8b8ba7;
--mag:#ff3ec9;--cyan:#38e8ff;--vio:#a06bff;--grn:#3cff8f;--red:#ff4d6d;--org:#ffab3c;--yel:#ffe23c}
*{box-sizing:border-box;margin:0;padding:0}
body{background:radial-gradient(1200px 600px at 50% -10%,#1a1030 0%,var(--bg) 60%);color:var(--tx);
font:15px/1.5 ui-monospace,"SF Mono",Menlo,Consolas,monospace;min-height:100vh;padding:18px}
.wrap{max-width:920px;margin:0 auto}
h1{font-size:44px;font-weight:800;letter-spacing:2px;text-align:center;
background:linear-gradient(90deg,var(--mag),var(--vio),var(--cyan));-webkit-background-clip:text;background-clip:text;color:transparent}
.sub{text-align:center;color:var(--mut);margin:2px 0 4px;letter-spacing:1px}
.by{text-align:center;color:var(--mut);font-size:12px;margin-bottom:20px}
.by b{color:var(--yel)}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;margin-bottom:16px;
box-shadow:0 8px 30px rgba(0,0,0,.35)}
.row{display:flex;gap:16px;flex-wrap:wrap}
.row>*{flex:1;min-width:220px}
.pill{display:inline-flex;align-items:center;gap:7px;padding:4px 12px;border-radius:999px;font-weight:700;font-size:13px}
.live{background:rgba(60,255,143,.12);color:var(--grn);border:1px solid rgba(60,255,143,.35)}
.off{background:rgba(255,77,109,.10);color:var(--red);border:1px solid rgba(255,77,109,.3)}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block}
.k{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:1px}
.v{font-size:18px;font-weight:700;word-break:break-all}
.v.mag{color:var(--mag)}.v.cyan{color:var(--cyan)}
.stat{display:flex;flex-direction:column;gap:2px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px}
button{font-family:inherit;font-weight:700;border:0;border-radius:11px;padding:12px 18px;cursor:pointer;
color:#0a0a12;transition:transform .08s,filter .15s;font-size:14px}
button:active{transform:translateY(1px)}
button:hover{filter:brightness(1.08)}
.btn-go{background:linear-gradient(90deg,var(--grn),var(--cyan));width:100%;font-size:17px;padding:15px}
.btn-stop{background:linear-gradient(90deg,var(--red),var(--org));width:100%;font-size:17px;padding:15px}
.btn-sm{background:var(--card2);color:var(--tx);border:1px solid var(--line);padding:7px 12px;font-size:12px}
.btn-kick{background:linear-gradient(90deg,var(--red),#c0304f);padding:6px 12px;font-size:12px}
label{display:block;color:var(--mut);font-size:12px;margin:10px 0 5px;text-transform:uppercase;letter-spacing:1px}
input,select{width:100%;background:var(--card2);border:1px solid var(--line);border-radius:9px;color:var(--tx);
padding:11px 12px;font:inherit}
input:focus,select:focus{outline:0;border-color:var(--mag)}
.inline{display:flex;gap:8px;align-items:center}
.toggles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;margin-top:6px}
.tog{display:flex;align-items:center;gap:9px;background:var(--card2);border:1px solid var(--line);border-radius:9px;padding:10px 12px;cursor:pointer}
.tog input{width:auto}
.sec{font-size:12px;color:var(--mut);letter-spacing:1px;text-transform:uppercase;margin:0 0 12px;border-bottom:1px solid var(--line);padding-bottom:8px}
.dev{display:flex;align-items:center;justify-content:space-between;gap:10px;background:var(--card2);
border:1px solid var(--line);border-radius:10px;padding:10px 13px;margin-bottom:8px}
.dev .m{font-size:12px;color:var(--mut)}
.sig{font-size:12px;padding:2px 8px;border-radius:6px;background:rgba(56,232,255,.1);color:var(--cyan)}
.qr{background:#fff;padding:10px;border-radius:12px;display:inline-block}
.qr img{display:block;width:190px;height:190px;image-rendering:pixelated}
.muted{color:var(--mut)}
.badge{font-size:12px;color:var(--org)}
.spark{width:100%;height:38px;display:block}
.hide{display:none}
.flash{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--card2);
border:1px solid var(--line);border-radius:10px;padding:10px 18px;font-size:13px;opacity:0;transition:opacity .2s;z-index:9}
.flash.show{opacity:1}
@media(max-width:560px){h1{font-size:32px}}
</style></head><body>
<div class=wrap>
<h1>PLUGG</h1>
<div class=sub>⚡ THE WiFi PLUG</div>
<div class=by>crafted by <b>@archnexus707</b></div>

<!-- STATUS -->
<div class=card id=statusCard>
  <div class=row style="align-items:center">
    <div style="flex:0 0 auto"><span id=statePill class="pill off">● offline</span></div>
    <div class=stat><span class=k>hotspot name</span><span class="v mag" id=sSsid>—</span></div>
    <div class=stat><span class=k>password</span><span class="v cyan" id=sPass>—</span></div>
  </div>
  <div class=grid style="margin-top:16px">
    <div class=stat><span class=k>internet in</span><span class=v id=sUplink>—</span></div>
    <div class=stat><span class=k>download</span><span class=v id=sRx>0 B/s</span></div>
    <div class=stat><span class=k>upload</span><span class=v id=sTx>0 B/s</span></div>
    <div class=stat><span class=k>auto-off</span><span class=v id=sOff>—</span></div>
  </div>
  <canvas class=spark id=spark></canvas>
</div>

<!-- CONTROLS: config (when off) -->
<div class="card" id=configCard>
  <div class=sec>set up the hotspot</div>
  <div id=detBox class=muted style="margin-bottom:10px">detecting radios…</div>
  <label>Hotspot name (call it anything)</label>
  <input id=fSsid maxlength=32 placeholder="e.g. HOPE-EVENT">
  <label>Password</label>
  <div class=inline><input id=fPass minlength=8 placeholder="min 8 chars">
    <button class=btn-sm id=genPass>random</button></div>
  <div class=row style="margin-top:4px">
    <div><label>Band</label>
      <select id=fBand><option value=2.4>2.4GHz — best range</option><option value=5>5GHz — faster</option></select></div>
    <div><label>Security</label>
      <select id=fWpa><option value=2>WPA2 (universal)</option><option value=3>WPA3/WPA2</option></select></div>
  </div>
  <div class=row style="margin-top:4px">
    <div><label>Max devices (0 = ∞)</label><input id=fMax type=number min=0 value=0></div>
    <div><label>Auto-off minutes (0 = never)</label><input id=fOff type=number min=0 value=0></div>
  </div>
  <div class=toggles>
    <label class=tog><input type=checkbox id=fIso checked> guest isolation</label>
    <label class=tog><input type=checkbox id=fWd checked> upstream watchdog</label>
    <label class=tog><input type=checkbox id=fAc checked> auto channel</label>
  </div>
  <div style="margin-top:16px"><button class=btn-go id=btnStart>⚡ START HOTSPOT</button></div>
  <div class=inline style="margin-top:10px">
    <select id=profSel><option value="">— load a profile —</option></select>
    <button class=btn-sm id=btnLoadProf>load</button>
  </div>
  <div class=inline style="margin-top:8px">
    <input id=profName maxlength=40 placeholder="save current settings as…">
    <button class=btn-sm id=btnSaveProf>💾 save</button>
  </div>
</div>

<!-- CONTROLS: running -->
<div class="card hide" id=runCard>
  <div class=row>
    <div class=qr><img id=qrImg alt="wifi qr"></div>
    <div style="flex:2">
      <div class=sec>connected devices <span id=devCount class=badge></span></div>
      <div id=devList><span class=muted>waiting for devices…</span></div>
      <div class=inline style="margin-top:12px">
        <button class=btn-sm id=btnUnban>clear ban-list</button>
        <span id=banInfo class=badge></span>
      </div>
    </div>
  </div>
  <div style="margin-top:16px"><button class=btn-stop id=btnStop>■ STOP + RESET EVERYTHING</button></div>
</div>

<div class=flash id=flash></div>
</div>
<script>
let prev=null, sparkData=[];
const $=s=>document.querySelector(s);
function flash(m){const f=$('#flash');f.textContent=m;f.classList.add('show');setTimeout(()=>f.classList.remove('show'),1800)}
async function api(path,opts={}){
  return fetch(path,Object.assign({},opts,{headers:Object.assign({'Content-Type':'application/json'},opts.headers||{})}));
}
function hr(bps){bps=bps||0; if(bps>=1048576)return (bps/1048576).toFixed(1)+' MB/s'; if(bps>=1024)return Math.round(bps/1024)+' KB/s'; return Math.round(bps)+' B/s'}
function fmtOff(sec){if(sec<=0)return '—';const h=sec/3600|0,m=(sec%3600)/60|0,s=sec%60;return `${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`}

function drawSpark(){
  const c=$('#spark'),w=c.width=c.clientWidth,h=c.height=38,ctx=c.getContext('2d');
  ctx.clearRect(0,0,w,h); if(sparkData.length<2)return;
  const max=Math.max(...sparkData,1),n=sparkData.length;
  ctx.beginPath();
  sparkData.forEach((v,i)=>{const x=i/(n-1)*w,y=h-(v/max)*(h-4)-2; i?ctx.lineTo(x,y):ctx.moveTo(x,y)});
  const g=ctx.createLinearGradient(0,0,w,0); g.addColorStop(0,'#ff3ec9'); g.addColorStop(1,'#38e8ff');
  ctx.strokeStyle=g; ctx.lineWidth=2; ctx.stroke();
}

function renderDevices(st){
  const el=$('#devList'); const cs=st.clients||[];
  $('#devCount').textContent=cs.length?`(${cs.length})`:'';
  $('#banInfo').textContent=st.banned>0?`${st.banned} banned`:'';
  if(!cs.length){el.innerHTML='<span class=muted>waiting for devices…</span>';return}
  el.innerHTML=cs.map(c=>`<div class=dev><div><div>${c.name&&c.name!=='-'?c.name:'device'}</div>
    <div class=m>${c.ip} · ${c.mac}</div></div>
    <div class=inline>${c.signal?`<span class=sig>${c.signal} dBm</span>`:''}
    <button class="btn-kick" data-mac="${c.mac}">kick</button></div></div>`).join('');
  el.querySelectorAll('.btn-kick').forEach(b=>b.onclick=async()=>{
    await api('/api/kick',{method:'POST',body:JSON.stringify({mac:b.dataset.mac})});flash('kicked + banned');});
}

async function tick(){
  let st; try{ st=await (await api('/api/status')).json(); }catch(e){ return; }
  const running=st.running;
  $('#statePill').className='pill '+(running?'live':'off');
  $('#statePill').textContent=running?'● LIVE':'● offline';
  $('#sSsid').textContent=st.ssid||'—';
  $('#sPass').textContent=st.pass||'—';
  $('#sUplink').innerHTML=(st.upstream_ssid||st.upstream||'—')+' '+
    (st.online?'<span class=sig style="background:rgba(60,255,143,.12);color:var(--grn)">online</span>':'<span class=sig style="background:rgba(255,77,109,.12);color:var(--red)">offline</span>');
  // rates from cumulative counters
  const now=Date.now()/1000;
  if(prev){const dt=Math.max(now-prev.t,1);
    const rx=Math.max(0,(st.rx-prev.rx)/dt), tx=Math.max(0,(st.tx-prev.tx)/dt);
    $('#sRx').textContent=hr(rx); $('#sTx').textContent=hr(tx);
    sparkData.push(rx+tx); if(sparkData.length>60)sparkData.shift(); drawSpark();
  }
  prev={t:now,rx:st.rx,tx:st.tx};
  $('#sOff').textContent=st.off_at>0?fmtOff(st.off_at-now|0):'—';
  $('#configCard').classList.toggle('hide',running);
  $('#runCard').classList.toggle('hide',!running);
  if(running){ if(!$('#qrImg').src||$('#qrImg').dataset.ssid!==st.ssid){$('#qrImg').src='/api/qr.png?t='+Date.now();$('#qrImg').dataset.ssid=st.ssid;} renderDevices(st); }
}

async function loadDetect(){
  try{const d=await (await api('/api/detect')).json();
    const u=d.upstream||{},a=d.ap||{};
    $('#detBox').innerHTML=`internet in: <b style=color:var(--cyan)>${u.iface||'?'}</b> ${u.usb?'(Alfa/USB)':''} → <b style=color:var(--grn)>${u.ssid||'not connected'}</b> `+
      `<span class=badge>${u.bands||''}G</span><br>hotspot on: <b style=color:var(--cyan)>${a.iface||'?'}</b> `+
      `<span class=muted>(${a.driver||''}, ${a.bands||''}G)</span>`;
    // disable 5GHz option if AP can't do it
    const opt5=$('#fBand').querySelector('option[value="5"]');
    if(a.has5===false){opt5.disabled=true;opt5.textContent='5GHz — (AP radio is 2.4-only)';}
    if(!$('#fSsid').value&&u.ssid)$('#fSsid').value=(u.ssid+'-share').replace(/\s+/g,'-');
  }catch(e){$('#detBox').textContent='could not detect radios';}
}
async function loadProfiles(list){
  try{const ps=list||await (await api('/api/profiles')).json();
    const sel=$('#profSel'); sel.innerHTML='<option value="">— load a profile —</option>';
    ps.forEach(p=>{const o=document.createElement('option');o.value=o.textContent=p;sel.appendChild(o)});
  }catch(e){}
}

$('#genPass').onclick=async()=>{const r=await (await api('/api/gen-pass',{method:'POST'})).json();$('#fPass').value=r.pass;};
$('#btnStart').onclick=async()=>{
  const cfg={ssid:$('#fSsid').value,pass:$('#fPass').value,band:$('#fBand').value,wpa_mode:$('#fWpa').value,
    maxsta:$('#fMax').value,offmins:$('#fOff').value,isolate:$('#fIso').checked,watchdog:$('#fWd').checked,autochan:$('#fAc').checked};
  const c=await (await api('/api/config',{method:'POST',body:JSON.stringify(cfg)})).json();
  if(!c.ok){flash(c.error||'config error');return;}
  $('#btnStart').textContent='⏳ starting…'; $('#btnStart').disabled=true;
  await api('/api/start',{method:'POST'});
  $('#btnStart').textContent='⚡ START HOTSPOT'; $('#btnStart').disabled=false;
  flash('hotspot live'); tick();
};
$('#btnStop').onclick=async()=>{if(!confirm('Stop the hotspot and reset everything?'))return;
  await api('/api/stop',{method:'POST'});prev=null;sparkData=[];flash('stopped & reset');tick();};
$('#btnUnban').onclick=async()=>{await api('/api/unban',{method:'POST'});flash('ban-list cleared');};
$('#btnLoadProf').onclick=async()=>{const n=$('#profSel').value;if(!n)return;
  const r=await (await api('/api/profile',{method:'POST',body:JSON.stringify({name:n})})).json();
  if(r.ok){const s=await (await api('/api/status')).json();
    $('#fSsid').value=s.ssid;$('#fPass').value=s.pass;$('#fMax').value=s.maxsta;
    $('#fBand').value=s.band==='a'?'5':'2.4';$('#fWpa').value=s.wpa_mode||'2';
    if('offmins'in s)$('#fOff').value=s.offmins; if('autochan'in s)$('#fAc').checked=s.autochan==='yes';
    $('#fIso').checked=s.isolate==='yes';$('#fWd').checked=s.watchdog==='yes';flash('profile "'+n+'" loaded');}
  else flash('could not load profile');};
$('#btnSaveProf').onclick=async()=>{
  const n=$('#profName').value.trim(); if(!n){flash('type a profile name first');return;}
  const cfg={ssid:$('#fSsid').value,pass:$('#fPass').value,band:$('#fBand').value,wpa_mode:$('#fWpa').value,
    maxsta:$('#fMax').value,offmins:$('#fOff').value,isolate:$('#fIso').checked,watchdog:$('#fWd').checked,autochan:$('#fAc').checked};
  const c=await (await api('/api/config',{method:'POST',body:JSON.stringify(cfg)})).json();
  if(!c.ok){flash(c.error||'need an SSID + 8-char password to save');return;}
  const r=await (await api('/api/profile/save',{method:'POST',body:JSON.stringify({name:n})})).json();
  if(r.ok){flash('saved profile: '+r.name); $('#profName').value=''; loadProfiles(r.profiles);}
  else flash(r.error||'save failed');};

loadDetect(); loadProfiles(); tick(); setInterval(tick,2000);
</script></body></html>"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, threaded=True)
