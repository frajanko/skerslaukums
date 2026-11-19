# Šķērslaukums — Bitterliha metode ar iPhone kameru

Tīmekļa lietotne (PWA) meža šķērslaukuma (G, m²/ha) mērīšanai ar leņķa skaitīšanas
(prizmas / relaskopa) metodi. LiDAR nav vajadzīgs — metode mēra tikai leņķi.

## Kā tas strādā
- Kameras attēlā tiek uzzīmēta **virtuālā prizma** (josla ar nobīdītu attēlu) vai **mērlīnijas**.
  Nobīde = kritiskais leņķis θ, kur BAF = 10 000 · sin²(θ/2).
- Lai leņķi pārvērstu ekrāna pikseļos, jāzina kameras fokusa attālums → **kalibrēšana**
  (priekšmets ar zināmu platumu zināmā attālumā).
- Slīpuma korekcija no telefona žiroskopa: sin(θ/2) · cos(slīpums).
- Sugu uzskaite, sastāva formula (piem. `6P3E1B`), vairāki laukumi nogabalā, vidējais G un 95 % ticamības intervāls,
  GPS koordinātas, kompasa „apgrieziena” indikators, CSV eksports (Excel, `;` atdalītājs).
- Strādā bezsaistē (service worker), dati glabājas telefonā (localStorage).

## Uzstādīšana iPhone
Kamerai Safari prasa **HTTPS**, tāpēc faili jāievieto jebkurā HTTPS statiskajā hostingā, piem.:
- **GitHub Pages**: izveido repozitoriju, augšupielādē visus failus, Settings → Pages → Deploy from branch.
- **Netlify Drop** (app.netlify.com/drop): ievelc mapi pārlūkā.

Tad iPhone Safari atver adresi → Kopīgot → **Pievienot sākuma ekrānam**.
Pirmajā palaišanā atļauj kameru, kustības sensorus un atrašanās vietu.

## Pirms mērīšanas — kalibrēšana
☰ → Iestatījumi → Kalibrēt. Novieto A4 lapu (29,7 cm) 3 m attālumā vai auto numura zīmi (52 cm) 5 m attālumā, perpendikulāri skatam,
ieslēdz 2× tālummaiņu, uzvelc līnijas uz latas malām, ievadi platumu un attālumu, saglabā.
Pārbaude: BAF 1 režīmā 10 cm plats priekšmets 5,00 m attālumā ir tieši robežkoks.

## Faili
| Fails | Saturs |
|---|---|
| `index.html` | lapas struktūra |
| `style.css` | izskats |
| `app.js` | kamera, sensori, zīmēšana, skaitīšana, saglabāšana, eksports |
| `calc.js` | formulas (BAF, leņķi, slīpums, sastāvs, statistika) |
| `sw.js`, `manifest.webmanifest`, `icons/` | bezsaistes darbība un instalēšana |

Pēc failu izmaiņām `sw.js` palielini `CACHE` versiju, lai telefons ielādētu jauno versiju.
