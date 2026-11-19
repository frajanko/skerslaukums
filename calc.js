// Šķērslaukuma (Bitterliha leņķa skaitīšanas) aprēķini — tīras funkcijas bez DOM.

const RAD = Math.PI / 180;

// Noklusētais fokusa attālums attiecībā pret video garāko malu.
// iPhone galvenā kamera ≈ 26 mm ekvivalents; 4:3 sensora platums ≈ 34,6 mm ekv.
// 26 / 34,6 ≈ 0,75. Tas ir tikai sākuma minējums — precizitātei JĀKALIBRĒ.
export const DEFAULT_F_LONG = 0.75;

export const SPECIES = [
  { id: 'P', name: 'Priede' },
  { id: 'E', name: 'Egle' },
  { id: 'B', name: 'Bērzs' },
  { id: 'A', name: 'Apse' },
  { id: 'M', name: 'Melnalksnis' },
  { id: 'Ba', name: 'Baltalksnis' },
  { id: 'O', name: 'Ozols' },
  { id: 'Os', name: 'Osis' },
  { id: 'L', name: 'Liepa' },
  { id: 'Kļ', name: 'Kļava' },
  { id: 'C', name: 'Cits' },
];

// sin(θ/2), kur θ — kritiskais leņķis. BAF = 10000·sin²(θ/2).
// Slīpuma korekcija: koks skaitās, ja horizontālais attālums ≤ R,
// t.i. slīpajā attālumā mērīts sin(θ/2) jāreizina ar cos(slīpums).
export function critSin(baf, slopeDeg = 0) {
  return (Math.sqrt(baf) / 100) * Math.cos(slopeDeg * RAD);
}

// Kritiskais leņķis grādos (bez slīpuma korekcijas).
export function critAngleDeg(baf) {
  return (2 * Math.asin(Math.sqrt(baf) / 100)) / RAD;
}

// Atstarpe ekrāna pikseļos starp mērlīnijām / prizmas nobīde.
// F — fokusa attālums ekrāna pikseļos. Cilindra (stumbra) malas centrā
// redzamas ±F·tan(asin(r/L)) attālumā no centra.
export function gaugeWidth(F, baf, slopeDeg = 0) {
  const s = Math.min(0.5, critSin(baf, slopeDeg));
  return 2 * F * Math.tan(Math.asin(s));
}

// Plakans priekšmets, perpendikulārs skata asij: ekrāna px = F·W/D (precīzi).
export function focalFromCalibration(px, widthM, distM) {
  return (px * distM) / widthM;
}

// Robežattālums (horizontāli, līdz stumbra centram), m.
export function maxDistance(dCm, baf) {
  return (0.5 * dCm) / Math.sqrt(baf);
}

// Leņķis, kurā aizmugurējā kamera skatās virs (+) / zem (−) horizonta, grādos.
// DeviceOrientation: kameras ass ir −Z; tās vertikālā komponente = −cosβ·cosγ.
export function pitchDeg(beta, gamma) {
  const v = -Math.cos(beta * RAD) * Math.cos(gamma * RAD);
  return Math.asin(Math.max(-1, Math.min(1, v))) / RAD;
}

export function totalCount(counts) {
  return Object.values(counts || {}).reduce((a, b) => a + b, 0);
}

export function plotBA(counts, baf) {
  return totalCount(counts) * baf;
}

// Sastāva formula pēc šķērslaukuma daļām desmitdaļās, piem. "6P3E1B+A".
export function composition(baBySpecies) {
  const entries = Object.entries(baBySpecies || {}).filter(([, v]) => v > 0);
  const total = entries.reduce((a, [, v]) => a + v, 0);
  if (!total) return '—';
  const parts = entries.map(([k, v]) => {
    const x = (v / total) * 10;
    return { k, x, n: Math.floor(x), rem: x - Math.floor(x) };
  });
  let left = 10 - parts.reduce((a, p) => a + p.n, 0);
  [...parts].sort((a, b) => b.rem - a.rem).forEach((p) => {
    if (left > 0) { p.n++; left--; }
  });
  parts.sort((a, b) => b.n - a.n || b.x - a.x);
  const main = parts.filter((p) => p.n > 0).map((p) => p.n + p.k).join('');
  const plus = parts.filter((p) => p.n === 0).map((p) => '+' + p.k).join('');
  return main + plus;
}

// Studenta t (95 %, divpusējs) brīvības pakāpēm 1..30.
const T95 = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
  2.201, 2.179, 2.16, 2.145, 2.131, 2.12, 2.11, 2.101, 2.093, 2.086,
  2.08, 2.074, 2.069, 2.064, 2.06, 2.056, 2.052, 2.048, 2.045, 2.042];

export function stats(values) {
  const n = values.length;
  if (!n) return { n: 0, mean: 0, sd: 0, se: 0, ci: 0, ciRel: 0 };
  const mean = values.reduce((a, b) => a + b, 0) / n;
  if (n < 2) return { n, mean, sd: 0, se: 0, ci: 0, ciRel: 0 };
  const sd = Math.sqrt(values.reduce((a, v) => a + (v - mean) ** 2, 0) / (n - 1));
  const se = sd / Math.sqrt(n);
  const t = n - 1 <= 30 ? T95[n - 2] : 1.96;
  const ci = t * se;
  return { n, mean, sd, se, ci, ciRel: mean ? (ci / mean) * 100 : 0 };
}
