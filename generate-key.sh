#!/bin/bash
# ============================================================
#  เจนนาเรทคีย์ — VPN License Key Generator (All-in-One)
#  รวม Install + Backend + Generate ในสคริปต์เดียว
# ============================================================

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/opt/license-server"
PORT=3000
DB_FILE="$INSTALL_DIR/licenses.json"

# ─── Banner ──────────────────────────────────────────────────
banner() {
  echo -e "${CYAN}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║   🔑  เจนนาเรทคีย์  —  VPN License Tool   ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─── Check & Install Node.js ─────────────────────────────────
ensure_node() {
  if command -v node &>/dev/null; then
    echo -e "${GREEN}✔ Node.js พบแล้ว: $(node -v)${NC}"
    return
  fi
  echo -e "${YELLOW}⚙ ติดตั้ง Node.js v20...${NC}"
  if command -v apt-get &>/dev/null; then
    # เปลี่ยน mirror เป็น Thailand เพื่อความเร็ว
    echo -e "${YELLOW}⚙ เปลี่ยน apt mirror → Thailand...${NC}"
    sudo sed -i 's|http://archive.ubuntu.com|http://th.archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null || true
    sudo sed -i 's|http://security.ubuntu.com|http://th.archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null || true
    # ตั้ง timeout ไม่ให้ค้าง
    echo 'Acquire::http::Timeout "30";' | sudo tee /etc/apt/apt.conf.d/99timeout > /dev/null
    echo 'Acquire::Retries "3";' | sudo tee -a /etc/apt/apt.conf.d/99timeout > /dev/null
    sudo apt-get update -qq
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v yum &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
    sudo yum install -y nodejs
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    command -v brew &>/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install node@20
  else
    echo -e "${RED}❌ ติดตั้ง Node.js เองที่ https://nodejs.org${NC}"; exit 1
  fi
}

# ─── Write server.js ─────────────────────────────────────────
write_server() {
  sudo mkdir -p "$INSTALL_DIR"
  sudo tee "$INSTALL_DIR/server.js" > /dev/null <<'SERVEREOF'
const express = require('express');
const crypto  = require('crypto');
const fs      = require('fs');
const path    = require('path');
const cors    = require('cors');

const app    = express();
const PORT   = process.env.PORT || 3000;
const DB     = path.join(__dirname, 'licenses.json');

app.use(cors());
app.use(express.json());
app.use(express.static(__dirname));

function loadDB() {
  if (!fs.existsSync(DB)) fs.writeFileSync(DB, JSON.stringify({ licenses: {} }));
  return JSON.parse(fs.readFileSync(DB, 'utf8'));
}
function saveDB(d) { fs.writeFileSync(DB, JSON.stringify(d, null, 2)); }

function genKey(prefix = 'VPN') {
  const s = () => crypto.randomBytes(4).toString('hex').toUpperCase();
  return `${prefix}-${s()}-${s()}-${s()}-${s()}`;
}

app.get('/health', (_,res) => res.json({ status:'ok', uptime:process.uptime() }));

// POST /generate-license  { owner, product, maxDevices, expireDays }
app.post('/generate-license', (req, res) => {
  const { owner, product='VPN', maxDevices=1, expireDays=365 } = req.body;
  if (!owner) return res.status(400).json({ error:'owner required' });
  const db  = loadDB();
  const key = genKey(product.toUpperCase().slice(0,5));
  const now = Date.now();
  db.licenses[key] = {
    key, owner, product,
    maxDevices : parseInt(maxDevices),
    activeDevices: [],
    createdAt  : now,
    expiresAt  : now + parseInt(expireDays)*86400000,
    status     : 'active'
  };
  saveDB(db);
  console.log(`[+] Generated: ${key} → ${owner}`);
  res.json({ success:true, license:db.licenses[key] });
});

// POST /verify-license  { key, deviceId }
app.post('/verify-license', (req, res) => {
  const { key, deviceId } = req.body;
  if (!key) return res.status(400).json({ error:'key required' });
  const db = loadDB();
  const L  = db.licenses[key];
  if (!L) return res.status(404).json({ valid:false, reason:'Not found' });
  if (L.status !== 'active') return res.json({ valid:false, reason:`Status: ${L.status}` });
  if (Date.now() > L.expiresAt) {
    L.status = 'expired'; saveDB(db);
    return res.json({ valid:false, reason:'Expired' });
  }
  if (deviceId && !L.activeDevices.includes(deviceId)) {
    if (L.activeDevices.length >= L.maxDevices)
      return res.json({ valid:false, reason:'Device limit reached' });
    L.activeDevices.push(deviceId); saveDB(db);
  }
  res.json({ valid:true, license:{
    key:L.key, owner:L.owner, product:L.product,
    expiresAt:L.expiresAt,
    daysLeft:Math.ceil((L.expiresAt-Date.now())/86400000),
    activeDevices:L.activeDevices.length, maxDevices:L.maxDevices
  }});
});

// POST /revoke-license  { key }
app.post('/revoke-license', (req, res) => {
  const { key } = req.body;
  const db = loadDB();
  if (!db.licenses[key]) return res.status(404).json({ error:'Not found' });
  db.licenses[key].status = 'revoked'; saveDB(db);
  console.log(`[-] Revoked: ${key}`);
  res.json({ success:true, message:`${key} revoked` });
});

// GET /api/check?key=...&ip=...  ← compat กับ chaiya-setup
app.get('/api/check', (req, res) => {
  const { key, ip } = req.query;
  if (!key) return res.json({ status:'error', msg:'No key provided' });
  const db = loadDB();
  const L  = db.licenses[key];
  if (!L) return res.json({ status:'error', msg:'License not found' });
  if (L.status === 'revoked') return res.json({ status:'error', msg:'License revoked' });
  if (Date.now() > L.expiresAt) {
    L.status = 'expired'; saveDB(db);
    return res.json({ status:'error', msg:'License expired' });
  }
  // บันทึก IP ที่ใช้งาน
  if (ip && !L.activeDevices.includes(ip)) {
    if (L.activeDevices.length >= L.maxDevices)
      return res.json({ status:'error', msg:'Device limit reached' });
    L.activeDevices.push(ip); saveDB(db);
  }
  const expiry = new Date(L.expiresAt).toISOString().split('T')[0];
  console.log(`[✓] License OK: ${key} | IP: ${ip}`);
  res.json({ status:'ok', msg:'License valid', expiry, owner:L.owner, product:L.product });
});

// GET /licenses
app.get('/licenses', (_,res) => {
  const db   = loadDB();
  const list = Object.values(db.licenses).map(l=>({
    ...l, daysLeft:Math.max(0,Math.ceil((l.expiresAt-Date.now())/86400000))
  }));
  res.json({ total:list.length, licenses:list });
});

app.listen(PORT, ()=>{
  console.log(`\n🔑 License Server → http://localhost:${PORT}`);
  console.log('   POST /generate-license | POST /verify-license');
  console.log('   POST /revoke-license   | GET  /licenses\n');
});
SERVEREOF

  sudo tee "$INSTALL_DIR/package.json" > /dev/null <<'PKGEOF'
{
  "name": "license-server",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
PKGEOF

  echo -e "${GREEN}✔ server.js เขียนแล้ว${NC}"
}

# ─── Write UI HTML ───────────────────────────────────────────
write_html() {
  sudo tee "$INSTALL_DIR/index.html" > /dev/null <<'HTMLEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>เจนนาเรทคีย์ — VPN License Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;500;600;700&family=Share+Tech+Mono&family=Sarabun:wght@300;400;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #050a0f;
    --surface: #0a1520;
    --panel: #0d1e2e;
    --border: #1a3a5c;
    --accent: #00d4ff;
    --accent2: #00ff9d;
    --accent3: #ff6b35;
    --text: #c8e6f5;
    --text-dim: #5a8aaa;
    --red: #ff3b5c;
    --gold: #ffd700;
    --glow: 0 0 20px rgba(0,212,255,0.3);
    --glow2: 0 0 20px rgba(0,255,157,0.3);
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Sarabun', sans-serif;
    min-height: 100vh;
    overflow-x: hidden;
    position: relative;
  }

  /* Grid background */
  body::before {
    content: '';
    position: fixed;
    inset: 0;
    background-image:
      linear-gradient(rgba(0,212,255,0.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(0,212,255,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
    z-index: 0;
  }

  /* Scanline overlay */
  body::after {
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,0.08) 2px,
      rgba(0,0,0,0.08) 4px
    );
    pointer-events: none;
    z-index: 999;
  }

  .container {
    max-width: 960px;
    margin: 0 auto;
    padding: 20px 16px 60px;
    position: relative;
    z-index: 1;
  }

  /* ── HEADER ── */
  header {
    text-align: center;
    padding: 40px 0 30px;
    position: relative;
  }

  .logo-ring {
    width: 80px; height: 80px;
    border-radius: 50%;
    border: 2px solid var(--accent);
    margin: 0 auto 16px;
    display: flex; align-items: center; justify-content: center;
    box-shadow: var(--glow), inset 0 0 30px rgba(0,212,255,0.1);
    animation: pulse 3s ease-in-out infinite;
    position: relative;
  }
  .logo-ring::before {
    content: '';
    position: absolute;
    inset: 6px;
    border-radius: 50%;
    border: 1px solid rgba(0,212,255,0.3);
    animation: spin 8s linear infinite;
  }
  .logo-ring svg { width: 36px; height: 36px; fill: var(--accent); filter: drop-shadow(0 0 8px var(--accent)); }

  @keyframes pulse {
    0%,100% { box-shadow: var(--glow), inset 0 0 30px rgba(0,212,255,0.1); }
    50% { box-shadow: 0 0 40px rgba(0,212,255,0.5), inset 0 0 40px rgba(0,212,255,0.2); }
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  h1 {
    font-family: 'Rajdhani', sans-serif;
    font-size: 2.2rem;
    font-weight: 700;
    letter-spacing: 4px;
    text-transform: uppercase;
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
    margin-bottom: 6px;
  }

  .subtitle {
    font-family: 'Share Tech Mono', monospace;
    color: var(--text-dim);
    font-size: 0.75rem;
    letter-spacing: 3px;
    text-transform: uppercase;
  }

  /* Server status bar */
  .status-bar {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    margin-top: 16px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.75rem;
    color: var(--text-dim);
  }
  .status-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--red);
    box-shadow: 0 0 6px var(--red);
    transition: all 0.5s;
  }
  .status-dot.online { background: var(--accent2); box-shadow: 0 0 6px var(--accent2); animation: blink 2s ease infinite; }
  @keyframes blink { 0%,100%{opacity:1} 50%{opacity:0.4} }

  /* Server URL input */
  .server-config {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 12px auto 0;
    max-width: 400px;
  }
  .server-config input {
    flex: 1;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 7px 12px;
    color: var(--text);
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.75rem;
    outline: none;
    transition: border-color 0.2s;
  }
  .server-config input:focus { border-color: var(--accent); }
  .server-config button {
    padding: 7px 14px;
    background: transparent;
    border: 1px solid var(--accent);
    border-radius: 6px;
    color: var(--accent);
    font-family: 'Rajdhani', sans-serif;
    font-size: 0.8rem;
    font-weight: 600;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s;
    white-space: nowrap;
  }
  .server-config button:hover { background: rgba(0,212,255,0.1); box-shadow: var(--glow); }

  /* ── TABS ── */
  .tabs {
    display: flex;
    gap: 4px;
    margin: 28px 0 0;
    border-bottom: 1px solid var(--border);
    padding-bottom: 0;
  }
  .tab {
    padding: 10px 18px;
    background: transparent;
    border: 1px solid transparent;
    border-bottom: none;
    border-radius: 6px 6px 0 0;
    color: var(--text-dim);
    font-family: 'Rajdhani', sans-serif;
    font-size: 0.9rem;
    font-weight: 600;
    letter-spacing: 1.5px;
    text-transform: uppercase;
    cursor: pointer;
    transition: all 0.2s;
    position: relative;
    bottom: -1px;
  }
  .tab:hover { color: var(--text); }
  .tab.active {
    color: var(--accent);
    border-color: var(--border);
    border-bottom-color: var(--bg);
    background: var(--bg);
  }
  .tab .tab-icon { margin-right: 6px; }

  /* ── PANELS ── */
  .panel {
    display: none;
    background: var(--panel);
    border: 1px solid var(--border);
    border-top: none;
    border-radius: 0 0 12px 12px;
    padding: 28px;
    animation: fadeIn 0.3s ease;
  }
  .panel.active { display: block; }
  @keyframes fadeIn { from{opacity:0;transform:translateY(8px)} to{opacity:1;transform:translateY(0)} }

  /* ── FORM ── */
  .form-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
  }
  @media(max-width:600px){ .form-grid{grid-template-columns:1fr;} }

  .form-group { display: flex; flex-direction: column; gap: 6px; }
  .form-group.full { grid-column: 1/-1; }

  label {
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.7rem;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  input[type=text], input[type=number], select {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 11px 14px;
    color: var(--text);
    font-family: 'Sarabun', sans-serif;
    font-size: 0.95rem;
    outline: none;
    transition: all 0.2s;
    width: 100%;
  }
  input:focus, select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 3px rgba(0,212,255,0.08);
  }
  select option { background: var(--panel); }

  /* ── BUTTONS ── */
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 12px 24px;
    border: none;
    border-radius: 8px;
    font-family: 'Rajdhani', sans-serif;
    font-size: 1rem;
    font-weight: 700;
    letter-spacing: 2px;
    text-transform: uppercase;
    cursor: pointer;
    transition: all 0.2s;
    position: relative;
    overflow: hidden;
  }
  .btn::after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(135deg, rgba(255,255,255,0.1), transparent);
    opacity: 0;
    transition: opacity 0.2s;
  }
  .btn:hover::after { opacity: 1; }
  .btn:active { transform: scale(0.97); }

  .btn-primary {
    background: linear-gradient(135deg, var(--accent), #0099bb);
    color: #000;
    box-shadow: 0 4px 20px rgba(0,212,255,0.3);
  }
  .btn-primary:hover { box-shadow: 0 6px 30px rgba(0,212,255,0.5); transform: translateY(-1px); }

  .btn-success {
    background: linear-gradient(135deg, var(--accent2), #00bb70);
    color: #000;
    box-shadow: 0 4px 20px rgba(0,255,157,0.3);
  }
  .btn-danger {
    background: linear-gradient(135deg, var(--red), #cc1133);
    color: #fff;
    box-shadow: 0 4px 20px rgba(255,59,92,0.3);
  }

  .btn-full { width: 100%; justify-content: center; margin-top: 8px; }

  /* ── RESULT BOX ── */
  .result-box {
    margin-top: 20px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 20px;
    display: none;
    position: relative;
    overflow: hidden;
  }
  .result-box::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
  }
  .result-box.show { display: block; animation: fadeIn 0.3s ease; }
  .result-box.error::before { background: var(--red); }

  .key-display {
    font-family: 'Share Tech Mono', monospace;
    font-size: 1.1rem;
    color: var(--gold);
    letter-spacing: 2px;
    text-shadow: 0 0 20px rgba(255,215,0,0.5);
    word-break: break-all;
    background: rgba(255,215,0,0.05);
    border: 1px solid rgba(255,215,0,0.2);
    border-radius: 8px;
    padding: 14px;
    margin: 12px 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    cursor: pointer;
    transition: all 0.2s;
  }
  .key-display:hover { background: rgba(255,215,0,0.08); }
  .copy-hint { font-size: 0.65rem; color: var(--text-dim); white-space: nowrap; }

  .info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 12px;
    margin-top: 12px;
  }
  .info-chip {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px 12px;
    text-align: center;
  }
  .info-chip .chip-label {
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.6rem;
    letter-spacing: 1.5px;
    color: var(--text-dim);
    text-transform: uppercase;
    margin-bottom: 4px;
  }
  .info-chip .chip-val {
    font-family: 'Rajdhani', sans-serif;
    font-size: 1.1rem;
    font-weight: 700;
    color: var(--accent);
  }

  /* ── LICENSE TABLE ── */
  .table-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 16px;
    gap: 12px;
    flex-wrap: wrap;
  }
  .table-title {
    font-family: 'Rajdhani', sans-serif;
    font-size: 1.1rem;
    font-weight: 700;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: var(--text);
  }
  .total-badge {
    background: rgba(0,212,255,0.1);
    border: 1px solid rgba(0,212,255,0.3);
    border-radius: 20px;
    padding: 4px 12px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.75rem;
    color: var(--accent);
  }

  .search-box {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 9px 14px;
    color: var(--text);
    font-family: 'Sarabun', sans-serif;
    font-size: 0.9rem;
    outline: none;
    width: 220px;
    transition: border-color 0.2s;
  }
  .search-box:focus { border-color: var(--accent); }

  .licenses-list { display: flex; flex-direction: column; gap: 10px; }

  .license-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px;
    transition: all 0.2s;
    position: relative;
    overflow: hidden;
  }
  .license-card::before {
    content: '';
    position: absolute;
    left: 0; top: 0; bottom: 0;
    width: 3px;
    background: var(--accent2);
    border-radius: 3px 0 0 3px;
  }
  .license-card.expired::before { background: var(--red); }
  .license-card.revoked::before { background: var(--text-dim); }
  .license-card:hover { border-color: rgba(0,212,255,0.3); transform: translateX(2px); }

  .lc-top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
    margin-bottom: 10px;
  }
  .lc-key {
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.85rem;
    color: var(--gold);
    cursor: pointer;
  }
  .lc-key:hover { text-shadow: 0 0 10px var(--gold); }

  .status-badge {
    padding: 3px 10px;
    border-radius: 20px;
    font-family: 'Rajdhani', sans-serif;
    font-size: 0.75rem;
    font-weight: 700;
    letter-spacing: 1px;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .badge-active { background: rgba(0,255,157,0.15); color: var(--accent2); border: 1px solid rgba(0,255,157,0.3); }
  .badge-expired { background: rgba(255,59,92,0.15); color: var(--red); border: 1px solid rgba(255,59,92,0.3); }
  .badge-revoked { background: rgba(90,138,170,0.15); color: var(--text-dim); border: 1px solid rgba(90,138,170,0.3); }

  .lc-meta {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
    font-size: 0.82rem;
    color: var(--text-dim);
  }
  .lc-meta span { display: flex; align-items: center; gap: 4px; }
  .lc-meta strong { color: var(--text); }

  .lc-actions { margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap; }

  .btn-sm {
    padding: 6px 14px;
    font-size: 0.78rem;
    border-radius: 6px;
    border: none;
    cursor: pointer;
    font-family: 'Rajdhani', sans-serif;
    font-weight: 700;
    letter-spacing: 1px;
    text-transform: uppercase;
    transition: all 0.2s;
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .btn-sm-danger { background: rgba(255,59,92,0.15); color: var(--red); border: 1px solid rgba(255,59,92,0.3); }
  .btn-sm-danger:hover { background: rgba(255,59,92,0.3); }
  .btn-sm-info { background: rgba(0,212,255,0.1); color: var(--accent); border: 1px solid rgba(0,212,255,0.3); }
  .btn-sm-info:hover { background: rgba(0,212,255,0.2); }

  /* Days left bar */
  .days-bar { margin-top: 10px; }
  .days-bar-track {
    height: 4px;
    background: var(--border);
    border-radius: 4px;
    overflow: hidden;
  }
  .days-bar-fill {
    height: 100%;
    border-radius: 4px;
    background: linear-gradient(90deg, var(--accent2), var(--accent));
    transition: width 0.8s ease;
  }
  .days-bar-fill.low { background: linear-gradient(90deg, var(--red), var(--accent3)); }

  /* ── VERIFY PANEL ── */
  .verify-result {
    margin-top: 20px;
    display: none;
  }
  .verify-result.show { display: block; animation: fadeIn 0.3s ease; }

  .valid-card {
    background: rgba(0,255,157,0.05);
    border: 1px solid rgba(0,255,157,0.2);
    border-radius: 12px;
    padding: 24px;
    position: relative;
    overflow: hidden;
  }
  .valid-card::before {
    content: '✓';
    position: absolute;
    right: 20px; top: 10px;
    font-size: 5rem;
    color: rgba(0,255,157,0.05);
    font-weight: 900;
    line-height: 1;
  }
  .invalid-card {
    background: rgba(255,59,92,0.05);
    border: 1px solid rgba(255,59,92,0.2);
    border-radius: 12px;
    padding: 24px;
  }

  .valid-title {
    font-family: 'Rajdhani', sans-serif;
    font-size: 1.4rem;
    font-weight: 700;
    letter-spacing: 3px;
    color: var(--accent2);
    text-transform: uppercase;
    margin-bottom: 16px;
  }
  .invalid-title {
    font-family: 'Rajdhani', sans-serif;
    font-size: 1.4rem;
    font-weight: 700;
    letter-spacing: 3px;
    color: var(--red);
    text-transform: uppercase;
    margin-bottom: 8px;
  }

  /* ── TOAST ── */
  .toast-container {
    position: fixed;
    bottom: 24px;
    right: 24px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    z-index: 9999;
  }
  .toast {
    background: var(--panel);
    border: 1px solid var(--border);
    border-left: 3px solid var(--accent);
    border-radius: 8px;
    padding: 12px 18px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.8rem;
    color: var(--text);
    box-shadow: 0 4px 20px rgba(0,0,0,0.5);
    animation: slideIn 0.3s ease, fadeOut 0.3s ease 2.7s forwards;
    max-width: 280px;
  }
  .toast.error { border-left-color: var(--red); }
  .toast.success { border-left-color: var(--accent2); }
  @keyframes slideIn { from{transform:translateX(100%);opacity:0} to{transform:translateX(0);opacity:1} }
  @keyframes fadeOut { to{opacity:0;transform:translateX(20px)} }

  /* ── LOADING ── */
  .spinner {
    display: inline-block;
    width: 16px; height: 16px;
    border: 2px solid rgba(0,0,0,0.3);
    border-top-color: currentColor;
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
  }

  /* ── EMPTY STATE ── */
  .empty-state {
    text-align: center;
    padding: 40px 20px;
    color: var(--text-dim);
  }
  .empty-state svg { width: 48px; height: 48px; margin-bottom: 12px; opacity: 0.3; fill: var(--text-dim); }
  .empty-state p { font-family: 'Share Tech Mono', monospace; font-size: 0.8rem; letter-spacing: 1px; }

  .section-title {
    font-family: 'Rajdhani', sans-serif;
    font-size: 1.1rem;
    font-weight: 700;
    letter-spacing: 2px;
    color: var(--accent);
    text-transform: uppercase;
    margin-bottom: 20px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .section-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border), transparent);
  }

  /* ── REVOKE PANEL ── */
  .danger-zone {
    background: rgba(255,59,92,0.05);
    border: 1px solid rgba(255,59,92,0.2);
    border-radius: 10px;
    padding: 20px;
    margin-top: 16px;
  }
  .danger-zone label { color: rgba(255,59,92,0.8); }
  .danger-zone input:focus { border-color: var(--red); box-shadow: 0 0 0 3px rgba(255,59,92,0.08); }
</style>
</head>
<body>

<div class="container">
  <!-- HEADER -->
  <header>
    <div class="logo-ring">
      <svg viewBox="0 0 24 24"><path d="M12 2C8.13 2 5 5.13 5 9c0 2.61 1.34 4.9 3.36 6.23L7 22h10l-1.36-6.77C17.66 13.9 19 11.61 19 9c0-3.87-3.13-7-7-7zm0 2c2.76 0 5 2.24 5 5 0 1.79-.94 3.36-2.36 4.23L14 14H10l-.64-2.77C7.94 10.36 7 8.79 7 9c0-2.76 2.24-5 5-5z"/></svg>
    </div>
    <h1>เจนนาเรทคีย์</h1>
    <div class="subtitle">VPN License Management System</div>

    <div class="server-config">
      <input type="text" id="serverUrl" value="http://localhost:3000" placeholder="Server URL">
      <button onclick="checkHealth()">เชื่อมต่อ</button>
    </div>
    <div class="status-bar">
      <div class="status-dot" id="statusDot"></div>
      <span id="statusText" style="font-size:0.72rem">ไม่ได้เชื่อมต่อ</span>
    </div>
  </header>

  <!-- TABS -->
  <div class="tabs">
    <button class="tab active" onclick="switchTab('generate',this)"><span class="tab-icon">⚡</span>สร้างคีย์</button>
    <button class="tab" onclick="switchTab('verify',this)"><span class="tab-icon">🔍</span>ตรวจสอบ</button>
    <button class="tab" onclick="switchTab('list',this)"><span class="tab-icon">📋</span>ดูทั้งหมด</button>
    <button class="tab" onclick="switchTab('revoke',this)"><span class="tab-icon">🚫</span>ยกเลิก</button>
  </div>

  <!-- GENERATE PANEL -->
  <div class="panel active" id="panel-generate">
    <div class="section-title">⚡ สร้าง License Key ใหม่</div>
    <div class="form-grid">
      <div class="form-group">
        <label>ชื่อเจ้าของ (Owner)</label>
        <input type="text" id="gen-owner" placeholder="เช่น John Doe">
      </div>
      <div class="form-group">
        <label>ชื่อสินค้า (Product)</label>
        <input type="text" id="gen-product" placeholder="VPN" value="VPN">
      </div>
      <div class="form-group">
        <label>จำนวนอุปกรณ์</label>
        <input type="number" id="gen-devices" value="1" min="1" max="100">
      </div>
      <div class="form-group">
        <label>อายุการใช้งาน (วัน)</label>
        <input type="number" id="gen-days" value="365" min="1">
      </div>
    </div>
    <button class="btn btn-primary btn-full" id="gen-btn" onclick="generateKey()">
      <span>⚡</span> สร้าง License Key
    </button>

    <div class="result-box" id="gen-result">
      <div class="section-title" style="font-size:0.9rem;margin-bottom:12px">✅ สร้างสำเร็จ</div>
      <div class="key-display" id="gen-key-display" onclick="copyKey('gen-key-val')">
        <span id="gen-key-val"></span>
        <span class="copy-hint">คลิกเพื่อคัดลอก</span>
      </div>
      <div class="info-grid" id="gen-info-grid"></div>
    </div>
  </div>

  <!-- VERIFY PANEL -->
  <div class="panel" id="panel-verify">
    <div class="section-title">🔍 ตรวจสอบ License Key</div>
    <div class="form-grid">
      <div class="form-group full">
        <label>License Key</label>
        <input type="text" id="ver-key" placeholder="VPN-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX" style="font-family:'Share Tech Mono',monospace;letter-spacing:1px">
      </div>
      <div class="form-group full">
        <label>Device ID (ไม่บังคับ)</label>
        <input type="text" id="ver-device" placeholder="device-001">
      </div>
    </div>
    <button class="btn btn-success btn-full" id="ver-btn" onclick="verifyKey()">
      <span>🔍</span> ตรวจสอบ
    </button>
    <div class="verify-result" id="ver-result"></div>
  </div>

  <!-- LIST PANEL -->
  <div class="panel" id="panel-list">
    <div class="table-header">
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span class="table-title">📋 License ทั้งหมด</span>
        <span class="total-badge" id="total-badge">0 รายการ</span>
      </div>
      <div style="display:flex;gap:8px;flex-wrap:wrap">
        <input class="search-box" type="text" id="search-box" placeholder="🔎 ค้นหา..." oninput="filterLicenses()">
        <button class="btn btn-primary" style="padding:9px 16px;font-size:0.8rem" onclick="loadLicenses()">⟳ รีเฟรช</button>
      </div>
    </div>
    <div class="licenses-list" id="licenses-list">
      <div class="empty-state">
        <svg viewBox="0 0 24 24"><path d="M20 4H4c-1.11 0-2 .89-2 2v12c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V6c0-1.11-.89-2-2-2zm-9 3v2H9V7h2zm0 4v2H9v-2h2zm0 4v2H9v-2h2zm6-8v2h-4V7h4zm0 4v2h-4v-2h4zm0 4v2h-4v-2h4z"/></svg>
        <p>กดรีเฟรชเพื่อโหลดข้อมูล</p>
      </div>
    </div>
  </div>

  <!-- REVOKE PANEL -->
  <div class="panel" id="panel-revoke">
    <div class="section-title">🚫 ยกเลิก License Key</div>
    <p style="color:var(--text-dim);font-size:0.9rem;margin-bottom:20px">การยกเลิกคีย์จะทำให้คีย์นั้นไม่สามารถใช้งานได้อีก โปรดตรวจสอบก่อนดำเนินการ</p>
    <div class="danger-zone">
      <div class="form-group">
        <label>License Key ที่ต้องการยกเลิก</label>
        <input type="text" id="rev-key" placeholder="VPN-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX" style="font-family:'Share Tech Mono',monospace;letter-spacing:1px">
      </div>
      <button class="btn btn-danger btn-full" style="margin-top:16px" id="rev-btn" onclick="revokeKey()">
        <span>🚫</span> ยืนยันยกเลิก License Key
      </button>
    </div>
    <div class="result-box" id="rev-result" style="margin-top:16px"></div>
  </div>
</div>

<!-- Toast container -->
<div class="toast-container" id="toastContainer"></div>

<script>
  let serverUrl = 'http://localhost:3000';
  let allLicenses = [];

  function getUrl() {
    return document.getElementById('serverUrl').value.replace(/\/$/, '');
  }

  // ── TABS ──
  function switchTab(name, el) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
    el.classList.add('active');
    document.getElementById('panel-' + name).classList.add('active');
    if (name === 'list') loadLicenses();
  }

  // ── TOAST ──
  function toast(msg, type = 'info') {
    const c = document.getElementById('toastContainer');
    const t = document.createElement('div');
    t.className = 'toast ' + type;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => t.remove(), 3000);
  }

  // ── HEALTH CHECK ──
  async function checkHealth() {
    const url = getUrl();
    const dot = document.getElementById('statusDot');
    const txt = document.getElementById('statusText');
    txt.textContent = 'กำลังเชื่อมต่อ...';
    try {
      const r = await fetch(url + '/health');
      const d = await r.json();
      if (d.status === 'ok') {
        dot.className = 'status-dot online';
        txt.textContent = `เชื่อมต่อแล้ว · Uptime ${Math.floor(d.uptime)}s`;
        toast('เชื่อมต่อ Server สำเร็จ ✓', 'success');
      }
    } catch {
      dot.className = 'status-dot';
      txt.textContent = 'ไม่สามารถเชื่อมต่อได้';
      toast('ไม่สามารถเชื่อมต่อ Server ได้', 'error');
    }
  }

  // ── GENERATE ──
  async function generateKey() {
    const owner = document.getElementById('gen-owner').value.trim();
    if (!owner) { toast('กรุณากรอกชื่อเจ้าของ', 'error'); return; }

    const btn = document.getElementById('gen-btn');
    btn.innerHTML = '<span class="spinner"></span> กำลังสร้าง...';
    btn.disabled = true;

    try {
      const body = {
        owner,
        product: document.getElementById('gen-product').value || 'VPN',
        maxDevices: parseInt(document.getElementById('gen-devices').value) || 1,
        expireDays: parseInt(document.getElementById('gen-days').value) || 365
      };
      const r = await fetch(getUrl() + '/generate-license', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
      const d = await r.json();
      if (d.success) {
        const L = d.license;
        document.getElementById('gen-key-val').textContent = L.key;
        document.getElementById('gen-info-grid').innerHTML = `
          <div class="info-chip"><div class="chip-label">Owner</div><div class="chip-val" style="font-size:0.85rem;font-family:'Sarabun'">${L.owner}</div></div>
          <div class="info-chip"><div class="chip-label">Product</div><div class="chip-val">${L.product}</div></div>
          <div class="info-chip"><div class="chip-label">Devices</div><div class="chip-val">${L.maxDevices}</div></div>
          <div class="info-chip"><div class="chip-label">วันหมดอายุ</div><div class="chip-val" style="font-size:0.85rem">${new Date(L.expiresAt).toLocaleDateString('th-TH')}</div></div>
        `;
        const box = document.getElementById('gen-result');
        box.className = 'result-box show';
        toast('สร้าง License Key สำเร็จ! ✓', 'success');
      } else {
        toast(d.error || 'เกิดข้อผิดพลาด', 'error');
      }
    } catch (e) {
      toast('ไม่สามารถเชื่อมต่อ Server ได้', 'error');
    }
    btn.innerHTML = '<span>⚡</span> สร้าง License Key';
    btn.disabled = false;
  }

  // ── VERIFY ──
  async function verifyKey() {
    const key = document.getElementById('ver-key').value.trim();
    if (!key) { toast('กรุณากรอก License Key', 'error'); return; }

    const btn = document.getElementById('ver-btn');
    btn.innerHTML = '<span class="spinner"></span> กำลังตรวจสอบ...';
    btn.disabled = true;

    try {
      const r = await fetch(getUrl() + '/verify-license', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key, deviceId: document.getElementById('ver-device').value })
      });
      const d = await r.json();
      const box = document.getElementById('ver-result');

      if (d.valid) {
        const L = d.license;
        box.innerHTML = `
          <div class="valid-card">
            <div class="valid-title">✓ License ถูกต้อง</div>
            <div class="key-display" onclick="copyKey('ver-key-show')" style="margin-bottom:14px">
              <span id="ver-key-show">${L.key}</span>
              <span class="copy-hint">คัดลอก</span>
            </div>
            <div class="info-grid">
              <div class="info-chip"><div class="chip-label">Owner</div><div class="chip-val" style="font-size:0.85rem;font-family:'Sarabun'">${L.owner}</div></div>
              <div class="info-chip"><div class="chip-label">Product</div><div class="chip-val">${L.product}</div></div>
              <div class="info-chip"><div class="chip-label">เหลือ</div><div class="chip-val">${L.daysLeft} <span style="font-size:0.7rem">วัน</span></div></div>
              <div class="info-chip"><div class="chip-label">Devices</div><div class="chip-val">${L.activeDevices}/${L.maxDevices}</div></div>
            </div>
          </div>`;
        toast('License Key ถูกต้อง ✓', 'success');
      } else {
        box.innerHTML = `
          <div class="invalid-card">
            <div class="invalid-title">✗ License ไม่ถูกต้อง</div>
            <p style="color:var(--text-dim);font-size:0.9rem">สาเหตุ: <strong style="color:var(--red)">${d.reason}</strong></p>
          </div>`;
        toast('License Key ไม่ถูกต้อง', 'error');
      }
      box.className = 'verify-result show';
    } catch {
      toast('ไม่สามารถเชื่อมต่อ Server ได้', 'error');
    }
    btn.innerHTML = '<span>🔍</span> ตรวจสอบ';
    btn.disabled = false;
  }

  // ── LOAD LICENSES ──
  async function loadLicenses() {
    try {
      const r = await fetch(getUrl() + '/licenses');
      const d = await r.json();
      allLicenses = d.licenses || [];
      document.getElementById('total-badge').textContent = `${d.total} รายการ`;
      renderLicenses(allLicenses);
    } catch {
      toast('โหลดข้อมูลไม่ได้ — ตรวจสอบ Server', 'error');
    }
  }

  function filterLicenses() {
    const q = document.getElementById('search-box').value.toLowerCase();
    renderLicenses(allLicenses.filter(l =>
      l.key.toLowerCase().includes(q) ||
      l.owner.toLowerCase().includes(q) ||
      l.product.toLowerCase().includes(q)
    ));
  }

  function renderLicenses(list) {
    const el = document.getElementById('licenses-list');
    if (!list.length) {
      el.innerHTML = `<div class="empty-state"><svg viewBox="0 0 24 24"><path d="M20 4H4c-1.11 0-2 .89-2 2v12c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V6c0-1.11-.89-2-2-2z"/></svg><p>ไม่พบข้อมูล</p></div>`;
      return;
    }
    el.innerHTML = list.map(L => {
      const pct = Math.min(100, Math.round((L.daysLeft / 365) * 100));
      const isLow = L.daysLeft < 30;
      const badgeClass = L.status === 'active' ? 'badge-active' : L.status === 'expired' ? 'badge-expired' : 'badge-revoked';
      const cardClass = L.status === 'expired' ? 'expired' : L.status === 'revoked' ? 'revoked' : '';
      return `
        <div class="license-card ${cardClass}">
          <div class="lc-top">
            <span class="lc-key" onclick="copyText('${L.key}')" title="คลิกเพื่อคัดลอก">${L.key}</span>
            <span class="status-badge ${badgeClass}">${L.status === 'active' ? '● ใช้งานอยู่' : L.status === 'expired' ? '✗ หมดอายุ' : '⊘ ยกเลิกแล้ว'}</span>
          </div>
          <div class="lc-meta">
            <span>👤 <strong>${L.owner}</strong></span>
            <span>📦 <strong>${L.product}</strong></span>
            <span>💻 <strong>${L.activeDevices?.length || 0}/${L.maxDevices}</strong> อุปกรณ์</span>
            <span>📅 <strong>${L.daysLeft}</strong> วันเหลือ</span>
          </div>
          ${L.status === 'active' ? `
          <div class="days-bar">
            <div class="days-bar-track">
              <div class="days-bar-fill ${isLow ? 'low' : ''}" style="width:${pct}%"></div>
            </div>
          </div>` : ''}
          <div class="lc-actions">
            <button class="btn-sm btn-sm-info" onclick="fillVerify('${L.key}')">🔍 ตรวจสอบ</button>
            ${L.status === 'active' ? `<button class="btn-sm btn-sm-danger" onclick="fillRevoke('${L.key}')">🚫 ยกเลิก</button>` : ''}
          </div>
        </div>`;
    }).join('');
  }

  // ── REVOKE ──
  async function revokeKey() {
    const key = document.getElementById('rev-key').value.trim();
    if (!key) { toast('กรุณากรอก License Key', 'error'); return; }
    if (!confirm(`ยืนยันยกเลิก: ${key}?`)) return;

    const btn = document.getElementById('rev-btn');
    btn.innerHTML = '<span class="spinner"></span> กำลังยกเลิก...';
    btn.disabled = true;

    try {
      const r = await fetch(getUrl() + '/revoke-license', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key })
      });
      const d = await r.json();
      const box = document.getElementById('rev-result');
      if (d.success) {
        box.innerHTML = `<p style="color:var(--accent2)">✅ ${d.message}</p>`;
        box.className = 'result-box show';
        toast('ยกเลิก License สำเร็จ', 'success');
      } else {
        box.innerHTML = `<p style="color:var(--red)">❌ ${d.error}</p>`;
        box.className = 'result-box error show';
        toast(d.error, 'error');
      }
    } catch {
      toast('ไม่สามารถเชื่อมต่อ Server ได้', 'error');
    }
    btn.innerHTML = '<span>🚫</span> ยืนยันยกเลิก License Key';
    btn.disabled = false;
  }

  // ── HELPERS ──
  function copyKey(id) {
    const val = document.getElementById(id).textContent;
    copyText(val);
  }
  function copyText(text) {
    navigator.clipboard.writeText(text).then(() => toast('คัดลอกแล้ว: ' + text.slice(0,20) + '...', 'success'));
  }
  function fillVerify(key) {
    document.getElementById('ver-key').value = key;
    document.querySelectorAll('.tab')[1].click();
  }
  function fillRevoke(key) {
    document.getElementById('rev-key').value = key;
    document.querySelectorAll('.tab')[3].click();
  }

  // Auto check on load
  window.addEventListener('load', () => setTimeout(checkHealth, 500));
</script>
</body>
</html>

HTMLEOF
  echo -e "${GREEN}✔ UI HTML เขียนแล้ว${NC}"
}


# ─── Install npm deps ─────────────────────────────────────────
install_deps() {
  echo -e "${YELLOW}⚙ ติดตั้ง npm packages...${NC}"
  sudo npm install --prefix "$INSTALL_DIR" --silent
  echo -e "${GREEN}✔ Dependencies พร้อมแล้ว${NC}"
}

# ─── Systemd service ─────────────────────────────────────────
setup_service() {
  if ! command -v systemctl &>/dev/null; then
    echo -e "${YELLOW}⚠ ไม่มี systemd — รัน manual ด้วย: node $INSTALL_DIR/server.js${NC}"
    return
  fi
  sudo tee /etc/systemd/system/license-server.service > /dev/null <<EOF
[Unit]
Description=VPN License Server (เจนนาเรทคีย์)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$(command -v node) $INSTALL_DIR/server.js
Restart=always
RestartSec=5
Environment=PORT=$PORT

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now license-server
  echo -e "${GREEN}✔ Service เปิดแล้ว (auto-start on boot)${NC}"
}

# ─── Open firewall port ───────────────────────────────────────
open_port() {
  if command -v ufw &>/dev/null; then
    sudo ufw allow $PORT/tcp &>/dev/null && echo -e "${GREEN}✔ ufw: port $PORT เปิดแล้ว${NC}"
  elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --add-port=$PORT/tcp &>/dev/null
    sudo firewall-cmd --reload &>/dev/null && echo -e "${GREEN}✔ firewalld: port $PORT เปิดแล้ว${NC}"
  fi
}

# ─── Wait for server ─────────────────────────────────────────
wait_server() {
  echo -ne "${YELLOW}⏳ รอ server พร้อม...${NC}"
  for i in $(seq 1 15); do
    if curl -sf http://localhost:$PORT/health &>/dev/null; then
      echo -e " ${GREEN}✔${NC}"; return 0
    fi
    sleep 1; echo -n "."
  done
  echo -e " ${RED}timeout${NC}"
}

# ─── Interactive: Generate a key ─────────────────────────────
generate_key_interactive() {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  echo -e "${CYAN}  🔑 สร้าง License Key ใหม่${NC}"
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  read -rp "  ชื่อเจ้าของ (Owner)  : " OWNER
  read -rp "  ชื่อสินค้า (Product) [VPN]: " PRODUCT
  PRODUCT="${PRODUCT:-VPN}"
  read -rp "  จำนวนอุปกรณ์ [1]     : " DEVICES
  DEVICES="${DEVICES:-1}"
  read -rp "  อายุ (วัน) [365]      : " DAYS
  DAYS="${DAYS:-365}"

  RESPONSE=$(curl -sf -X POST http://localhost:$PORT/generate-license \
    -H "Content-Type: application/json" \
    -d "{\"owner\":\"$OWNER\",\"product\":\"$PRODUCT\",\"maxDevices\":$DEVICES,\"expireDays\":$DAYS}")

  if [[ $? -eq 0 ]]; then
    KEY=$(echo "$RESPONSE" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
    echo ""
    echo -e "${GREEN}  ✅ สร้างสำเร็จ!${NC}"
    echo -e "  ${CYAN}License Key : ${YELLOW}$KEY${NC}"
    echo -e "  Owner       : $OWNER"
    echo -e "  Product     : $PRODUCT"
    echo -e "  Devices     : $DEVICES"
    echo -e "  Expire      : $DAYS วัน"
  else
    echo -e "${RED}  ❌ เกิดข้อผิดพลาด — ตรวจสอบว่า server ทำงานอยู่${NC}"
  fi
}

# ─── Menu ────────────────────────────────────────────────────
main_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "  1) สร้าง License Key ใหม่"
    echo -e "  2) ตรวจสอบ License Key"
    echo -e "  3) ดู License ทั้งหมด"
    echo -e "  4) ยกเลิก License Key"
    echo -e "  5) ออกจากโปรแกรม"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    read -rp "  เลือก [1-5]: " CHOICE

    case $CHOICE in
      1) generate_key_interactive ;;
      2)
        read -rp "  กรอก License Key: " K
        read -rp "  Device ID (เว้นว่างได้): " DID
        curl -s -X POST http://localhost:$PORT/verify-license \
          -H "Content-Type: application/json" \
          -d "{\"key\":\"$K\",\"deviceId\":\"$DID\"}" | \
          python3 -m json.tool 2>/dev/null || echo "ผล: $(curl -s ...)"
        ;;
      3)
        curl -s http://localhost:$PORT/licenses | python3 -m json.tool 2>/dev/null
        ;;
      4)
        read -rp "  กรอก License Key ที่ต้องการยกเลิก: " K
        curl -s -X POST http://localhost:$PORT/revoke-license \
          -H "Content-Type: application/json" \
          -d "{\"key\":\"$K\"}" | python3 -m json.tool 2>/dev/null
        ;;
      5) echo -e "${GREEN}ออกจากโปรแกรม${NC}"; exit 0 ;;
      *) echo -e "${RED}กรุณาเลือก 1-5${NC}" ;;
    esac
  done
}

# ─── MAIN ────────────────────────────────────────────────────
banner

# ถ้า server ยังไม่ได้ติดตั้ง → ติดตั้งก่อน
if [ ! -f "$INSTALL_DIR/server.js" ]; then
  echo -e "${YELLOW}📦 ยังไม่ได้ติดตั้ง — กำลัง setup...${NC}"
  ensure_node
  write_server
  write_html
  install_deps
  setup_service
  open_port
  wait_server
  echo -e "${GREEN}✅ ติดตั้งเสร็จแล้ว!${NC}"
else
  # เช็คว่า service ทำงานอยู่ไหม
  if ! curl -sf http://localhost:$PORT/health &>/dev/null; then
    echo -e "${YELLOW}⚙ เริ่ม server...${NC}"
    sudo systemctl start license-server 2>/dev/null || node "$INSTALL_DIR/server.js" &
    wait_server
  else
    echo -e "${GREEN}✔ Server ทำงานอยู่แล้ว${NC}"
  fi
fi

main_menu
