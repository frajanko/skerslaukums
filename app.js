import * as C from './calc.js';

const $ = (s) => document.querySelector(s);
const video = $('#video');
const canvas = $('#overlay');
const ctx = canvas.getContext('2d');

// ---------- Glabāšana ----------
const store = {
  get(k, d) {
    try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; }
  },
  set(k, v) {
    try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* privātais režīms u.c. */ }
  },
};

const BAFS = [1, 2, 3, 4];
const ZOOMS = [1, 2, 3];
const DEFAULTS = {
  baf: 2, mode: 'prism', slopeCorr: true, zoom: 2, species: 'P',
  fLong: C.DEFAULT_F_LONG, calib: null, bandFrac: 0.12,
};
const settings = Object.assign({}, DEFAULTS, store.get('sl.settings', {}));
let plots = store.get('sl.plots', []);
let cur = store.get('sl.cur', null) || newPlot('1', 1);

function newPlot(stand, no) {
  return { stand: String(stand), no, counts: {}, hist: [], started: Date.now(), cover: [] };
}
const saveSettings = () => store.set('sl.settings', settings);
const savePlots = () => store.set('sl.plots', plots);
const saveCur = () => store.set('sl.cur', cur);

// ---------- Palīgfunkcijas ----------
const fmt = (x, d = 1) => (Math.round(x * 10 ** d) / 10 ** d).toFixed(d).replace('.', ',');
const fmtN = (x) => (Number.isInteger(x) ? String(x) : fmt(x, 1));
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const spName = (id) => (C.SPECIES.find((s) => s.id === id) || { name: id }).name;
const parseNum = (v) => parseFloat(String(v).replace(',', '.'));

let flashTimer;
function flash(text, color) {
  const el = $('#flash');
  el.textContent = text;
  el.style.color = color || '#fff';
  el.classList.add('show');
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => el.classList.remove('show'), 450);
}

// ---------- Dialogi ----------
// Sistēmas confirm/alert/prompt iOS aptur kameras video, kas pēc tam paliek
// sastindzis, tāpēc izmantojam pašu logu lapas iekšienē.
function dialog({ title = '', text = '', fields = [], ok = 'Labi', cancel = 'Atcelt', danger = false }) {
  return new Promise((resolve) => {
    const root = $('#dialog');
    root.innerHTML = `<div class="dlg" role="dialog" aria-modal="true">
      ${title ? `<h3>${esc(title)}</h3>` : ''}
      ${text ? `<p>${esc(text).replace(/\n/g, '<br>')}</p>` : ''}
      ${fields.map((f) => `<label>${esc(f.label)}<input type="${f.type || 'text'}"${f.inputmode ? ` inputmode="${f.inputmode}"` : ''} value="${esc(f.value ?? '')}"></label>`).join('')}
      <div class="dlg-btns">
        ${cancel ? `<button class="btn ghost" data-r="0">${esc(cancel)}</button>` : ''}
        <button class="btn ${danger ? 'danger' : 'one'}" data-r="1">${esc(ok)}</button>
      </div></div>`;
    root.classList.remove('hidden');
    const finish = (yes) => {
      const vals = [...root.querySelectorAll('input')].map((i) => i.value);
      root.classList.add('hidden');
      root.innerHTML = '';
      root.onclick = root.onkeydown = null;
      lastFrameT = performance.now();
      resolve(fields.length ? (yes ? vals : null) : yes);
    };
    root.onclick = (e) => {
      const b = e.target.closest('[data-r]');
      if (b) finish(b.dataset.r === '1');
    };
    root.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); finish(true); } };
  });
}
const ask = (text, opts = {}) => dialog({ text, ...opts });
const tell = (text) => dialog({ text, cancel: '' });

// ---------- Sensori ----------
const sensor = { pitch: null, heading: null, pos: null };

function onOrient(e) {
  if (e.beta != null && e.gamma != null) sensor.pitch = C.pitchDeg(e.beta, e.gamma);
  let h = null;
  if (typeof e.webkitCompassHeading === 'number' && e.webkitCompassHeading >= 0) h = e.webkitCompassHeading;
  else if (e.absolute && e.alpha != null) h = (360 - e.alpha) % 360;
  if (h != null) {
    sensor.heading = h;
    markCoverage(h);
  }
}

function markCoverage(h) {
  if (!state.running || state.calib || state.panel) return;
  if (sensor.pitch == null || Math.abs(sensor.pitch) > 40) return;
  const bin = Math.floor(h / 5) % 72;
  if (!cur.cover.includes(bin)) {
    cur.cover.push(bin);
    saveCur();
  }
}

// Jāizsauc tieši no pieskāriena apstrādātāja (iOS prasība).
function requestOrientation() {
  try {
    if (typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function') {
      return DeviceOrientationEvent.requestPermission()
        .then((r) => { if (r === 'granted') addEventListener('deviceorientation', onOrient); })
        .catch(() => {});
    }
    addEventListener('deviceorientation', onOrient);
  } catch { /* nav sensora */ }
  return Promise.resolve();
}

function startGeo() {
  if (!('geolocation' in navigator)) return;
  try {
    navigator.geolocation.watchPosition(
      (p) => { sensor.pos = { lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy, t: Date.now() }; },
      () => {},
      { enableHighAccuracy: true, maximumAge: 30000, timeout: 30000 },
    );
  } catch { /* bez GPS */ }
}

let wakeLock = null;
async function keepAwake() {
  try { if ('wakeLock' in navigator) wakeLock = await navigator.wakeLock.request('screen'); } catch { /* nav atbalsta */ }
}

// ---------- Kamera ----------
let stream = null;
async function startCamera() {
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } },
  });
  video.srcObject = stream;
  const track = stream.getVideoTracks()[0];
  if (track) track.addEventListener('unmute', () => video.play().catch(() => {}));
  await video.play();
  lastFrameT = performance.now();
}

// Kameras uzraugs: ja video apstājies vai kadri vairs nenāk (iOS to dara pēc
// sistēmas logiem, zvaniem, Control Center u.c.), atsāk atskaņošanu vai kameru.
let lastFrameT = performance.now();
let lastPlayTry = 0, lastRestart = 0, restarting = false, framesSeen = false;
if ('requestVideoFrameCallback' in HTMLVideoElement.prototype) {
  const onVF = () => { lastFrameT = performance.now(); framesSeen = true; video.requestVideoFrameCallback(onVF); };
  video.requestVideoFrameCallback(onVF);
} else {
  video.addEventListener('timeupdate', () => { lastFrameT = performance.now(); framesSeen = true; });
}
video.addEventListener('pause', () => { if (state.running) video.play().catch(() => {}); });

async function ensureVideo() {
  if (!state.running || restarting || document.visibilityState !== 'visible') return;
  const now = performance.now();
  const track = stream && stream.getVideoTracks()[0];
  // Kadru plūsmai uzticamies tikai tad, ja tā vispār ir strādājusi.
  const stall = framesSeen ? now - lastFrameT : 0;
  if (!track || track.readyState === 'ended' || (stall > 3000 && now - lastRestart > 5000)) {
    restarting = true;
    lastRestart = now;
    try { await startCamera(); } catch { /* mēģinās vēlreiz pēc 5 s */ }
    lastFrameT = performance.now();
    restarting = false;
  } else if ((video.paused || stall > 700) && now - lastPlayTry > 1000) {
    lastPlayTry = now;
    video.play().catch(() => {});
  }
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible' || !state.running) return;
  keepAwake();
  lastFrameT = performance.now();
  ensureVideo();
});

// ---------- Stāvoklis ----------
const state = {
  running: false,
  panel: false,
  tab: 'plots',
  calib: null, // { x1, x2, active }
};

// ---------- Ģeometrija ----------
// S — video px → ekrāna px mērogs (object-fit: cover × tālummaiņa).
// F — fokusa attālums ekrāna CSS pikseļos.
function geom() {
  const W = canvas.clientWidth, H = canvas.clientHeight;
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return null;
  const cover = Math.max(W / vw, H / vh);
  const S = cover * settings.zoom;
  const F = settings.fLong * Math.max(vw, vh) * S;
  return { W, H, vw, vh, S, F, cx: W / 2, cy: H / 2 };
}

function currentSlope() {
  return settings.slopeCorr && sensor.pitch != null ? sensor.pitch : 0;
}

// Zīmē video daļu, droši apgriežot avota taisnstūri (Safari to prasa).
function drawVideoRect(sx, sy, sw, sh, dx, dy, dw, dh, vw, vh) {
  const kx = dw / sw, ky = dh / sh;
  if (sx < 0) { dx -= sx * kx; dw += sx * kx; sw += sx; sx = 0; }
  if (sy < 0) { dy -= sy * ky; dh += sy * ky; sh += sy; sy = 0; }
  if (sx + sw > vw) { const o = sx + sw - vw; sw -= o; dw -= o * kx; }
  if (sy + sh > vh) { const o = sy + sh - vh; sh -= o; dh -= o * ky; }
  if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
  ctx.drawImage(video, sx, sy, sw, sh, dx, dy, dw, dh);
}

function vline(x, y0, y1, color, width = 1.5) {
  ctx.lineCap = 'butt';
  ctx.strokeStyle = 'rgba(0,0,0,.75)';
  ctx.lineWidth = width + 2;
  ctx.beginPath(); ctx.moveTo(x, y0); ctx.lineTo(x, y1); ctx.stroke();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.beginPath(); ctx.moveTo(x, y0); ctx.lineTo(x, y1); ctx.stroke();
}

function label(text, x, y, align = 'center', color = '#fff') {
  ctx.font = '600 12px -apple-system, system-ui, sans-serif';
  ctx.textAlign = align;
  ctx.textBaseline = 'middle';
  ctx.lineWidth = 3;
  ctx.strokeStyle = 'rgba(0,0,0,.8)';
  ctx.strokeText(text, x, y);
  ctx.fillStyle = color;
  ctx.fillText(text, x, y);
}

// ---------- Zīmēšana ----------
let dpr = 1;
function resizeCanvas() {
  dpr = Math.min(window.devicePixelRatio || 1, 3);
  const w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
}

function frame() {
  requestAnimationFrame(frame);
  if (!state.running || state.panel) return;
  ensureVideo();
  resizeCanvas();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
  const g = geom();
  if (!g) return;
  if (state.calib) drawCalib(g);
  else drawGauge(g);
  updateSlopeInfo();
}

function drawGauge(g) {
  const { W, H, cx, cy } = g;
  const slope = currentSlope();
  const w = C.gaugeWidth(g.F, settings.baf, slope);
  const bandH = Math.max(50, Math.round(H * settings.bandFrac));
  const y0 = cy - bandH / 2, y1 = cy + bandH / 2;

  if (settings.mode === 'prism') {
    // Virtuālā prizma: josla ar attēlu, nobīdītu par kritisko leņķi.
    ctx.save();
    ctx.beginPath(); ctx.rect(0, y0, W, bandH); ctx.clip();
    ctx.fillStyle = '#000'; ctx.fillRect(0, y0, W, bandH);
    const sx = g.vw / 2 + (0 - cx) / g.S;
    const sy = g.vh / 2 + (y0 - cy) / g.S;
    drawVideoRect(sx, sy, W / g.S, bandH / g.S, w, y0, W, bandH, g.vw, g.vh);
    ctx.restore();
    ctx.strokeStyle = 'rgba(255,239,90,.85)';
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(0, y0 + 0.5); ctx.lineTo(W, y0 + 0.5); ctx.moveTo(0, y1 - 0.5); ctx.lineTo(W, y1 - 0.5); ctx.stroke();
    // Centra atzīme
    vline(cx, y0 - 14, y0, '#ffef5a', 1.5);
    vline(cx, y1, y1 + 14, '#ffef5a', 1.5);
  } else {
    // Mērlīnijas: stumbrs platāks par atstarpi → skaitās.
    const xl = cx - w / 2, xr = cx + w / 2;
    vline(xl, y0, y1, '#ffef5a', 1.5);
    vline(xr, y0, y1, '#ffef5a', 1.5);
    ctx.strokeStyle = 'rgba(255,239,90,.6)';
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(xl - 18, cy); ctx.lineTo(xl, cy); ctx.moveTo(xr, cy); ctx.lineTo(xr + 18, cy); ctx.stroke();
  }

  const ang = (2 * Math.asin(Math.min(0.5, C.critSin(settings.baf, slope)))) * 180 / Math.PI;
  label(`${fmt(w, 1)} px · ${fmt(ang, 2)}°`, cx, y1 + 26);
  drawCoverage(g);
}

function drawCoverage(g) {
  const r = 24, x = g.W - r - 14, y = 160;
  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,.45)';
  ctx.beginPath(); ctx.arc(x, y, r + 8, 0, Math.PI * 2); ctx.fill();
  ctx.lineWidth = 6;
  ctx.strokeStyle = 'rgba(255,255,255,.18)';
  ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.stroke();
  ctx.strokeStyle = '#7bd389';
  for (const b of cur.cover) {
    const a0 = (b * 5 - 90) * Math.PI / 180, a1 = ((b + 1) * 5 - 90) * Math.PI / 180;
    ctx.beginPath(); ctx.arc(x, y, r, a0, a1 + 0.01); ctx.stroke();
  }
  if (sensor.heading != null) {
    const a = (sensor.heading - 90) * Math.PI / 180;
    ctx.strokeStyle = '#fff'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + Math.cos(a) * (r - 6), y + Math.sin(a) * (r - 6)); ctx.stroke();
  }
  ctx.restore();
  label(sensor.heading == null ? 'nav kompasa' : `${cur.cover.length * 5}°`, x, y + r + 20);
}

function drawCalib(g) {
  const { H, cx } = g;
  const c = state.calib;
  ['x1', 'x2'].forEach((k) => {
    vline(cx + c[k], 0, H, c.active === k ? '#ffef5a' : 'rgba(255,239,90,.7)', c.active === k ? 1.5 : 1);
  });
  const p = Math.abs(c.x2 - c.x1);
  $('#cPx').textContent = `${fmt(p, 1)} px`;
}

function updateSlopeInfo() {
  const el = $('#slopeInfo');
  const t = sensor.pitch == null ? '∠ –' : `∠ ${fmt(sensor.pitch, 0)}°${settings.slopeCorr ? '' : ' (izsl.)'}`;
  if (el.textContent !== t) el.textContent = t;
}

// ---------- Kalibrēšanas vilkšana ----------
let drag = null;
canvas.addEventListener('pointerdown', (e) => {
  if (!state.calib) return;
  const g = geom(); if (!g) return;
  const x = e.clientX - g.cx;
  const k = Math.abs(x - state.calib.x1) <= Math.abs(x - state.calib.x2) ? 'x1' : 'x2';
  state.calib.active = k;
  drag = { k, startX: e.clientX, orig: state.calib[k] };
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener('pointermove', (e) => {
  if (!drag || !state.calib) return;
  state.calib[drag.k] = drag.orig + (e.clientX - drag.startX);
});
canvas.addEventListener('pointerup', () => { drag = null; });
canvas.addEventListener('pointercancel', () => { drag = null; });

function nudge(d) {
  if (!state.calib) return;
  state.calib[state.calib.active] += d;
}

function startCalib() {
  closePanel();
  state.calib = { x1: -60, x2: 60, active: 'x1' };
  const prev = settings.calib;
  if (prev) {
    $('#cW').value = String(+prev.widthCm.toFixed(2)).replace('.', ',');
    $('#cD').value = String(+prev.distM.toFixed(3)).replace('.', ',');
  }
  $('#bottom').classList.add('hidden');
  $('#calibBar').classList.remove('hidden');
}

function endCalib() {
  state.calib = null;
  $('#calibBar').classList.add('hidden');
  $('#bottom').classList.remove('hidden');
  renderAll();
}

async function saveCalib() {
  const g = geom();
  if (!g) { await tell('Kamera vēl nav gatava.'); return; }
  const p = Math.abs(state.calib.x2 - state.calib.x1);
  const Wm = parseNum($('#cW').value) / 100;
  const D = parseNum($('#cD').value);
  if (!(Wm > 0) || !(D > 0) || p < 10) { await tell('Pārbaudi platumu, attālumu un līniju novietojumu.'); return; }
  const F = C.focalFromCalibration(p, Wm, D);
  const fLong = F / (Math.max(g.vw, g.vh) * g.S);
  const hfov = hfovDeg(fLong, g.vw, g.vh);
  if (fLong < 0.35 || fLong > 1.8) {
    if (!(await ask(`Rezultāts izskatās neparasts (redzes leņķis ${fmt(hfov, 1)}°). Saglabāt tik un tā?`, { ok: 'Saglabāt' }))) return;
  }
  if (!state.calib) return;
  settings.fLong = fLong;
  settings.calib = { t: Date.now(), vLong: Math.max(g.vw, g.vh), vShort: Math.min(g.vw, g.vh), widthCm: Wm * 100, distM: D, px: p, zoom: settings.zoom };
  saveSettings();
  endCalib();
  flash(`Kalibrēts: ${fmt(hfov, 1)}°`, '#7bd389');
}

function hfovDeg(fLong, vw, vh) {
  return (2 * Math.atan((vw / 2) / (fLong * Math.max(vw, vh))) * 180) / Math.PI;
}

// ---------- Skaitīšana ----------
// BAF nosaka skaitīšanas leņķi, tāpēc jau saskaitītos kokus nevar pārrēķināt
// uz citu BAF — mainot BAF laukuma vidū, skaitīšana jāsāk no jauna.
async function setBaf(b) {
  if (b === settings.baf) return true;
  const n = C.totalCount(cur.counts);
  if (n > 0) {
    const ok = await ask(
      `Šajā laukumā jau saskaitīti ${fmtN(n)} koki ar BAF ${settings.baf}.\n\n` +
      `Ar BAF ${b} ir cits skaitīšanas leņķis, tāpēc koki jāpārskaita no jauna.`,
      { title: `Mainīt uz BAF ${b}?`, ok: 'Nodzēst un mainīt', danger: true },
    );
    if (!ok) return false;
    cur.counts = {};
    cur.hist = [];
    cur.cover = [];
    cur.started = Date.now();
    saveCur();
  }
  settings.baf = b;
  saveSettings();
  renderAll();
  flash(`BAF ${b}`);
  return true;
}

function add(v) {
  const sp = settings.species;
  cur.counts[sp] = (cur.counts[sp] || 0) + v;
  cur.hist.push([sp, v]);
  saveCur();
  renderBottom();
  flash(`${v === 0.5 ? '+½' : '+1'} ${spName(sp)}`, v === 0.5 ? '#ffd166' : '#7bd389');
}

function undo() {
  const h = cur.hist.pop();
  if (!h) return;
  const [sp, v] = h;
  cur.counts[sp] = (cur.counts[sp] || 0) - v;
  if (cur.counts[sp] <= 0) delete cur.counts[sp];
  saveCur();
  renderBottom();
  flash(`−${v === 0.5 ? '½' : '1'} ${spName(sp)}`, '#ff6b6b');
}

async function editMeta() {
  const r = await dialog({
    title: 'Laukuma dati',
    fields: [
      { label: 'Nogabala numurs / nosaukums', value: cur.stand },
      { label: 'Laukuma numurs', value: String(cur.no), type: 'number', inputmode: 'numeric' },
    ],
    ok: 'Saglabāt',
  });
  if (!r) return;
  cur.stand = r[0].trim() || cur.stand;
  const no = parseInt(r[1], 10);
  if (no > 0) cur.no = no;
  saveCur();
  renderBottom();
}

async function savePlot() {
  const n = C.totalCount(cur.counts);
  const cov = cur.cover.length * 5;
  if (n === 0 && !(await ask('Nav saskaitīts neviens koks. Saglabāt laukumu ar G = 0?', { ok: 'Saglabāt' }))) return;
  if (sensor.heading != null && cov < 300 && !(await ask(`Apgriezts tikai ~${cov}°. Saglabāt tik un tā?`, { ok: 'Saglabāt' }))) return;
  const pos = sensor.pos && Date.now() - sensor.pos.t < 180000 ? sensor.pos : null;
  const plot = {
    id: Date.now(), stand: cur.stand, no: cur.no, t: Date.now(), baf: settings.baf,
    counts: { ...cur.counts }, lat: pos?.lat ?? null, lon: pos?.lon ?? null, acc: pos?.acc ?? null,
    slopeCorr: settings.slopeCorr, calibrated: !!settings.calib, cover: sensor.heading != null ? cov : null,
  };
  plots.push(plot);
  savePlots();
  const G = C.plotBA(plot.counts, plot.baf);
  cur = newPlot(cur.stand, cur.no + 1);
  saveCur();
  renderBottom();
  flash(`Saglabāts: G = ${fmt(G, 1)}`, '#7bd389');
}

// ---------- Apakšējā panelis ----------
function renderBottom() {
  $('#standLbl').textContent = cur.stand;
  $('#plotLbl').textContent = cur.no;
  $('#species').innerHTML = C.SPECIES.map((s) => {
    const n = cur.counts[s.id];
    return `<button class="chip${s.id === settings.species ? ' sel' : ''}" data-sp="${esc(s.id)}">${esc(s.name)}${n ? `<span class="n">${fmtN(n)}</span>` : ''}</button>`;
  }).join('');
  const N = C.totalCount(cur.counts);
  $('#sumN').textContent = fmtN(N);
  $('#sumG').textContent = fmt(N * settings.baf, 1);
  const ba = {};
  for (const [k, v] of Object.entries(cur.counts)) ba[k] = v * settings.baf;
  $('#sumF').textContent = C.composition(ba);
}

function renderTop() {
  $('#bafBtn').textContent = `BAF ${settings.baf}`;
  $('#zoomBtn').textContent = `${settings.zoom}×`;
  $('#modeBtn').textContent = settings.mode === 'prism' ? 'Prizma' : 'Līnijas';
  video.style.transform = `scale(${settings.zoom})`;
  const warn = $('#calibWarn');
  let msg = '';
  if (!settings.calib) msg = 'Nav kalibrēts — rezultāti aptuveni';
  else if (video.videoWidth && Math.max(video.videoWidth, video.videoHeight) !== settings.calib.vLong) msg = 'Kameras izšķirtspēja mainījusies — kalibrē vēlreiz';
  warn.textContent = msg;
  warn.classList.toggle('hidden', !msg || !!state.calib);
}

function renderAll() { renderTop(); renderBottom(); }

function setZoom(z) {
  if (state.calib) {
    const k = z / settings.zoom;
    state.calib.x1 *= k; state.calib.x2 *= k;
  }
  settings.zoom = z;
  saveSettings();
  renderTop();
}

// ---------- Izvēlne ----------
function openPanel(tab) {
  state.panel = true;
  if (tab) state.tab = tab;
  $('#panel').classList.remove('hidden');
  renderPanel();
}
function closePanel() {
  state.panel = false;
  lastFrameT = performance.now();
  $('#panel').classList.add('hidden');
  renderAll();
}

function renderPanel() {
  document.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('sel', b.dataset.tab === state.tab));
  const body = $('#pbody');
  if (state.tab === 'plots') body.innerHTML = plotsHTML();
  else if (state.tab === 'settings') body.innerHTML = settingsHTML();
  else body.innerHTML = helpHTML();
  body.scrollTop = 0;
}

function groupByStand() {
  const m = new Map();
  for (const p of plots) {
    if (!m.has(p.stand)) m.set(p.stand, []);
    m.get(p.stand).push(p);
  }
  return m;
}

function plotsHTML() {
  if (!plots.length) {
    return `<p class="empty">Vēl nav saglabātu laukumu.<br>Saskaiti kokus un spied „Saglabāt laukumu”.</p>`;
  }
  let html = `<div class="btnrow"><button class="btn one" data-act="export">Eksportēt CSV</button><button class="btn danger" data-act="clearAll">Dzēst visus</button></div>`;
  for (const [stand, list] of groupByStand()) {
    const Gs = list.map((p) => C.plotBA(p.counts, p.baf));
    const st = C.stats(Gs);
    const ba = {};
    for (const p of list) for (const [k, v] of Object.entries(p.counts)) ba[k] = (ba[k] || 0) + (v * p.baf) / list.length;
    html += `<div class="card">
      <div class="head"><div><div class="sub">Nogabals</div><b>${esc(stand)}</b></div>
      <div style="text-align:right"><div class="big">${fmt(st.mean, 1)}</div><div class="sub">m²/ha vidēji</div></div></div>
      <div class="sub" style="margin-top:6px">Laukumi: ${st.n} · sastāvs <b style="color:var(--fg)">${C.composition(ba)}</b>${st.n > 1 ? ` · ±${fmt(st.ci, 1)} m²/ha (95 %, ${fmt(st.ciRel, 0)} %)` : ''}</div>
      <table><tr><th>Nr.</th><th class="num">BAF</th><th class="num">Koki</th><th class="num">G</th><th>Sastāvs</th><th></th></tr>
      ${list.map((p) => {
        const pba = {};
        for (const [k, v] of Object.entries(p.counts)) pba[k] = v * p.baf;
        return `<tr><td>${esc(p.no)}</td><td class="num">${p.baf}</td><td class="num">${fmtN(C.totalCount(p.counts))}</td><td class="num"><b>${fmt(C.plotBA(p.counts, p.baf), 1)}</b></td><td>${C.composition(pba)}</td><td class="num"><button class="x" data-act="del" data-id="${p.id}" aria-label="Dzēst">✕</button></td></tr>`;
      }).join('')}
      </table></div>`;
  }
  return html;
}

function settingsHTML() {
  const vw = video.videoWidth, vh = video.videoHeight;
  const cal = settings.calib;
  const hfov = vw ? `${fmt(hfovDeg(settings.fLong, vw, vh), 1)}°` : '–';
  const angles = BAFS.map((b) => `BAF ${b} → ${fmt(C.critAngleDeg(b), 3)}°`).join(' · ');
  return `
  <h2>Pamatlaukuma faktors (BAF)</h2>
  <div class="seg">${BAFS.map((b) => `<button data-act="baf" data-v="${b}" class="${settings.baf === b ? 'sel' : ''}">${b}</button>`).join('')}</div>
  <p class="sub" style="color:var(--muted);font-size:13px">${angles}. Izvēlies tā, lai laukumā saskaitītu ~8–20 kokus.</p>

  <h2>Skats</h2>
  <div class="seg">
    <button data-act="mode" data-v="prism" class="${settings.mode === 'prism' ? 'sel' : ''}">Prizma</button>
    <button data-act="mode" data-v="lines" class="${settings.mode === 'lines' ? 'sel' : ''}">Mērlīnijas</button>
  </div>
  <label class="toggle"><span>Slīpuma korekcija (pēc telefona slīpuma)</span><input type="checkbox" data-act="slope" ${settings.slopeCorr ? 'checked' : ''}></label>

  <h2>Kalibrēšana</h2>
  <div class="card">
    <div>${cal ? `<span class="ok">Kalibrēts</span> ${new Date(cal.t).toLocaleDateString('lv-LV')} — ${fmt(cal.widthCm, 0)} cm no ${fmt(cal.distM, 2)} m` : '<span class="bad">Nav kalibrēts</span> — izmanto aptuvenu noklusējumu'}</div>
    <div class="sub">Horizontālais redzes leņķis: ${hfov} · video ${vw || '–'}×${vh || '–'}</div>
    <div class="btnrow"><button class="btn one" data-act="calib">Kalibrēt</button>${cal ? '<button class="btn ghost" data-act="resetCalib">Atiestatīt</button>' : ''}</div>
    <p class="sub">Ieteikums: A4 lapa (29,7 cm) 3 m attālumā vai auto numura zīme (52 cm) 5 m attālumā, mērīts no telefona, 2× tālummaiņa. Atstarpei jābūt vismaz ~100 px. 1 px kļūda pie 100 px ≈ 1 % kļūda platumā ≈ 2 % kļūda G.</p>
  </div>

  <h2>Robežkoka pārbaude</h2>
  <div class="card">
    <div class="row">
      <label>Caurmērs 1,3 m, cm<input id="bD" type="text" inputmode="decimal" autocomplete="off"></label>
      <label>Attālums līdz centram, m<input id="bL" type="text" inputmode="decimal" autocomplete="off"></label>
    </div>
    <div id="bRes" class="result sub">Ievadi caurmēru, lai redzētu robežattālumu (BAF ${settings.baf}).</div>
    <p class="sub">Attālums horizontāli no laukuma centra līdz stumbra <b>centram</b> (līdz mizai + ½ caurmēra).</p>
  </div>`;
}

function helpHTML() {
  return `
  <h2>Kā mērīt</h2>
  <ol>
    <li>Pirms pirmās lietošanas <b>nokalibrē</b> kameru (Iestatījumi → Kalibrēt).</li>
    <li>Nostājies laukuma centrā. Turi telefonu vertikāli; telefonam jāpaliek virs centra punkta — apgriezies ap to, nevis ap sevi.</li>
    <li>Pavērs dzelteno joslu uz stumbra <b>1,3 m augstumā</b>, stumbru — ekrāna centrā.</li>
    <li><b>Prizmas skats:</b> joslā redzams nobīdīts attēls. Ja nobīdītais stumbra gabals vēl <i>pārklājas</i> ar stumbru virs/zem joslas → <b>+1</b>. Ja malas tieši sakrīt → <b>+½</b>. Ja starp tiem ir sprauga → neskaita.</li>
    <li><b>Mērlīniju skats:</b> stumbrs platāks par atstarpi starp līnijām → +1, vienāds → +½, šaurāks → neskaita.</li>
    <li>Pirms skaitīšanas izvēlies koku sugu. Apgriezies pilnu apli — gredzens augšā rāda, cik jau apskatīts.</li>
    <li><b>G = koku skaits × BAF</b> (m²/ha). Nogabalā noliec vairākus laukumus — lietotne rēķina vidējo un ticamības intervālu.</li>
  </ol>
  <h2>Precizitāte</h2>
  <ul>
    <li>LiDAR nav vajadzīgs: metode mēra tikai leņķi, nevis attālumu.</li>
    <li>Lielākā kļūdu avota iespēja ir kalibrēšana un neskaidri robežkoki. Šaubu gadījumā izmanto „Robežkoka pārbaudi”.</li>
    <li>Slīpumā ieslēdz slīpuma korekciju un mērķē uz 1,3 m augstumu — lietotne izmanto telefona slīpumu.</li>
    <li>Neaizmirsti aizsegtos kokus — paej sānis, bet atgriezies centrā, pirms vērtē.</li>
    <li>Ja maini kameras izšķirtspēju vai iOS versiju, kalibrē vēlreiz.</li>
  </ul>`;
}

function updateBorderline() {
  const d = parseNum($('#bD')?.value), L = parseNum($('#bL')?.value);
  const el = $('#bRes');
  if (!el) return;
  if (!(d > 0)) { el.className = 'result sub'; el.textContent = `Ievadi caurmēru, lai redzētu robežattālumu (BAF ${settings.baf}).`; return; }
  const R = C.maxDistance(d, settings.baf);
  if (!(L > 0)) { el.className = 'result'; el.textContent = `Robežattālums: ${fmt(R, 2)} m`; return; }
  const diff = R - L;
  if (Math.abs(diff) < 0.005 * R) { el.className = 'result mid'; el.textContent = `Robežkoks (R = ${fmt(R, 2)} m) → +½`; }
  else if (diff > 0) { el.className = 'result ok'; el.textContent = `Skaitās (R = ${fmt(R, 2)} m) → +1`; }
  else { el.className = 'result bad'; el.textContent = `Neskaitās (R = ${fmt(R, 2)} m)`; }
}

// ---------- CSV ----------
function csv() {
  const sp = C.SPECIES.map((s) => s.id);
  const head = ['nogabals', 'laukums', 'datums', 'laiks', 'platums', 'garums', 'gps_precizitate_m', 'BAF', 'slipuma_korekcija', 'kalibrets', 'apgriezts_gradi', ...sp, 'koki_kopa', 'G_m2_ha', 'sastavs'];
  const q = (v) => {
    const s = String(v ?? '');
    return /[;"\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const num = (x, d) => (x == null ? '' : x.toFixed(d).replace('.', ','));
  const rows = plots.map((p) => {
    const d = new Date(p.t);
    const pba = {};
    for (const [k, v] of Object.entries(p.counts)) pba[k] = v * p.baf;
    return [
      p.stand, p.no, d.toLocaleDateString('lv-LV'), d.toLocaleTimeString('lv-LV'),
      num(p.lat, 6), num(p.lon, 6), num(p.acc, 0), p.baf, p.slopeCorr ? 'jā' : 'nē', p.calibrated ? 'jā' : 'nē', p.cover ?? '',
      ...sp.map((k) => num(p.counts[k] || 0, 1)), num(C.totalCount(p.counts), 1), num(C.plotBA(p.counts, p.baf), 1), C.composition(pba),
    ].map(q).join(';');
  });
  return '﻿' + [head.join(';'), ...rows].join('\r\n');
}

async function exportCSV() {
  const name = `skerslaukums_${new Date().toISOString().slice(0, 10)}.csv`;
  const blob = new Blob([csv()], { type: 'text/csv;charset=utf-8' });
  try {
    const file = new File([blob], name, { type: 'text/csv' });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file], title: name });
      return;
    }
  } catch (e) {
    if (e && e.name === 'AbortError') return;
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
}

// ---------- Notikumi ----------
$('#startBtn').addEventListener('click', async () => {
  const orientP = requestOrientation(); // pirms jebkura await
  $('#startErr').textContent = '';
  try {
    await startCamera();
  } catch (e) {
    $('#startErr').textContent = window.isSecureContext
      ? 'Neizdevās atvērt kameru. Atļauj piekļuvi kamerai (Iestatījumi → Safari → Kamera).'
      : 'Kamerai vajadzīgs HTTPS savienojums. Atver lietotni no https:// adreses.';
    return;
  }
  await orientP;
  startGeo();
  keepAwake();
  state.running = true;
  $('#start').classList.add('hidden');
  renderAll();
});

$('#bafBtn').addEventListener('click', () => {
  setBaf(BAFS[(BAFS.indexOf(settings.baf) + 1) % BAFS.length] || 2);
});
$('#zoomBtn').addEventListener('click', () => setZoom(ZOOMS[(ZOOMS.indexOf(settings.zoom) + 1) % ZOOMS.length] || 1));
$('#modeBtn').addEventListener('click', () => {
  settings.mode = settings.mode === 'prism' ? 'lines' : 'prism';
  saveSettings();
  renderTop();
});
$('#menuBtn').addEventListener('click', () => (state.panel ? closePanel() : openPanel()));
$('#closePanel').addEventListener('click', closePanel);
$('#metaBtn').addEventListener('click', editMeta);
$('#oneBtn').addEventListener('click', () => add(1));
$('#halfBtn').addEventListener('click', () => add(0.5));
$('#undoBtn').addEventListener('click', undo);
$('#saveBtn').addEventListener('click', savePlot);
$('#species').addEventListener('click', (e) => {
  const b = e.target.closest('[data-sp]');
  if (!b) return;
  settings.species = b.dataset.sp;
  saveSettings();
  renderBottom();
});

$('#nudgeL').addEventListener('click', () => nudge(-0.5));
$('#nudgeR').addEventListener('click', () => nudge(0.5));
$('#cCancel').addEventListener('click', endCalib);
$('#cSave').addEventListener('click', saveCalib);

document.querySelector('.tabs').addEventListener('click', (e) => {
  const b = e.target.closest('[data-tab]');
  if (!b) return;
  state.tab = b.dataset.tab;
  renderPanel();
});

$('#pbody').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const act = b.dataset.act;
  if (act === 'export') exportCSV();
  else if (act === 'clearAll') {
    if (await ask('Dzēst VISUS saglabātos laukumus? To nevar atsaukt.', { ok: 'Dzēst visus', danger: true })) { plots = []; savePlots(); renderPanel(); }
  } else if (act === 'del') {
    const id = Number(b.dataset.id);
    const p = plots.find((x) => x.id === id);
    if (p && (await ask(`Dzēst nogabala ${p.stand} laukumu ${p.no}?`, { ok: 'Dzēst', danger: true }))) { plots = plots.filter((x) => x.id !== id); savePlots(); renderPanel(); }
  } else if (act === 'baf') { await setBaf(Number(b.dataset.v)); renderPanel(); }
  else if (act === 'mode') { settings.mode = b.dataset.v; saveSettings(); renderPanel(); }
  else if (act === 'calib') startCalib();
  else if (act === 'resetCalib') {
    if (await ask('Atiestatīt kalibrēšanu uz noklusējumu?', { ok: 'Atiestatīt', danger: true })) { settings.fLong = C.DEFAULT_F_LONG; settings.calib = null; saveSettings(); renderPanel(); }
  }
});
$('#pbody').addEventListener('change', (e) => {
  if (e.target.dataset.act === 'slope') { settings.slopeCorr = e.target.checked; saveSettings(); }
});
$('#pbody').addEventListener('input', (e) => {
  if (e.target.id === 'bD' || e.target.id === 'bL') updateBorderline();
});

video.addEventListener('loadedmetadata', renderTop);
window.addEventListener('resize', renderTop);

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

renderAll();
requestAnimationFrame(frame);
