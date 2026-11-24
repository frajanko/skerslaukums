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
ieslēdz 2× tālummaiņu, uzvelc līnijas uz priekšmeta malām, ievadi platumu un attālumu, saglabā.
Pārbaude: BAF 1 režīmā 10 cm plats priekšmets 5,00 m attālumā ir tieši robežkoks.

## iOS lietotne (mape `ios/`) — šķērslaukums + koku caurmērs un augstums
Native lietotne iPhone **Pro** modeļiem (LiDAR). Augšā pārslēdz **Šķērslaukums | Koki**.
Safari tīmekļa lietotnēm LiDAR datus nedod, tāpēc šī daļa nav PWA. Tīmekļa versija (augstāk) paliek tiem, kam nav iPhone Pro.

**Šķērslaukums** — augšā kameras attēls ar apaļu tēmēkli, virs pogām **prizmas logs**: tēmēkļa apkārtne palielināta
(2×/3×/4×), augšējā pusē reālais attēls, apakšējā — nobīdīts par kritisko leņķi. Pārējais kā PWA (prizma / mērlīnijas, BAF 1–4, sugas, sastāvs, laukumi, vidējais G ar 95 % intervālu,
GPS, robežkoka pārbaude, CSV ar tām pašām kolonnām), bet **bez kalibrēšanas**: ARKit dod kameras precīzo fokusa attālumu.
Slīpums un apgrieziena aplis nāk no AR izsekošanas (kompass nav vajadzīgs).

**Koki**
1. **Caurmērs** — 1–3 m no koka novieto tēmēkli stumbra vidū 1,3 m augstumā (pēc acs). Baltās līnijas rāda,
   kur lietotne redz stumbra malas. Spied „Mērīt” — sekundes laikā tiek savākti LiDAR punkti ±4 cm joslā šajā augstumā,
   un tiem pielāgots riņķis (metode „aplis”). Ja riņķis nav ticams, D aprēķina pēc stumbra leņķiskā platuma (metode „malas”):
   r = d·sin(α/2) / (1 − sin(α/2)). Izmērītās malas paliek AR skatā kā zaļas līnijas.
2. **Augstums** — atkāpies (ideāli ~ koka augstuma attālumā), tēmē galotni. ARKit seko telefona pozīcijai,
   augstums = punkts, kur tēmēšanas stars šķērso stumbra asi, mīnus zeme (1,3 m zem caurmēra mērīšanas vietas).

**Tikai D** — režīms tikai caurmēru mērīšanai (bez augstuma): katrs izmērītais caurmērs uzreiz tiek saglabāts
ar izvēlēto sugu, ↶ atsauc pēdējo saglabāto koku.

**Paraugl.** — apļveida parauglaukums ar R = 12,62 m (500 m²). Tēmē uz centra mietiņa pamatni → „Atzīmēt centru”;
AR skatā parādās laukuma robeža. Mērot caurmērus, katram kokam aprēķina horizontālo attālumu no centra līdz stumbra
asij (ARKit koordinātas) — iekšā / robežkoks (±30 cm, pārbaudīt ar mērlenti) / ārā. Atkārtoti mērīts koks tiek aizstāts.
Rādītāji: N/ha, G m²/ha, D̄, Dg, sastāvs; nogabalam — vidējie no visiem laukumiem ar 95 % ticamības intervālu G.
CSV: kopsavilkums pa laukumiem + visi koki.
Modeļkoki: pēc caurmēra var izmērīt koka augstumu. Sugas H = koka ar Dg augstums — no Näslunda augstuma līknes
h = 1,3 + (d / (a + b·d))² (≥ 3 modeļkoki ar caurmēru starpību ≥ 4 cm), citādi modeļkoku vidējais; audzes H —
sugu H, svērti pēc G. Nogabalā līkni veido no visu laukumu modeļkokiem.
Krāja: M = Σ G_sugas · HF(sugas H), HF — veidaugstumu (H·f) tabula pēc sugas, 9–40 m (`ios/KokuMeritajs/Volume.swift`,
lineāra interpolācija). Sugai bez modeļkokiem lieto audzes H (rezultāts atzīmēts ar „≈”).
Ja AR izsekošana tiek atiestatīta (vai lietotne aizvērta), centru atzīmē no jauna uz tā paša mietiņa un pārmēra vienu
jau izmērītu koku: no tā vektora no centra vecajā un jaunajā sistēmā aprēķina pagriezienu ap vertikāli un pārnes
visus iepriekšējās sesijas kokus (dublikātu atpazīšana un AR gredzeni atkal strādā).

Saglabātie koki (nogabals, nr., suga, D, H) → saraksts ar kopsavilkumu pa sugām → CSV (Excel, `;`).

**Būvēšana** — Mac nav vajadzīgs. Katrs `ios/` izmaiņu push uz `main` palaiž GitHub Actions
(`.github/workflows/ios.yml`): XcodeGen → xcodebuild bez parakstīšanas → `KokuMeritajs.ipa`
relīzē [ios-latest](https://github.com/frajanko/skerslaukums/releases/tag/ios-latest).

**Instalēšana ar Sideloadly (Windows, bez maksas)**
1. Uzinstalē iTunes un iCloud no apple.com (ne Microsoft Store versijas) un [Sideloadly](https://sideloadly.io).
2. Lejupielādē `KokuMeritajs.ipa` no relīzes *ios-latest*.
3. Pieslēdz iPhone ar kabeli, telefonā apstiprini „Uzticēties šim datoram”.
4. Sideloadly: ievelc `.ipa`, ievadi savu Apple ID, spied **Start**.
5. iPhone: Iestatījumi → Konfidencialitāte un drošība → **Izstrādātāja režīms** → ieslēgt (restartējas).
   Iestatījumi → Vispārīgi → VPN un ierīču pārvaldība → uzticies savam Apple ID.
6. Bezmaksas Apple ID paraksts der **7 dienas** — pēc tam atkārto 4. soli (dati telefonā saglabājas).
   Sideloadly var to darīt automātiski pa Wi-Fi, ja dators ir ieslēgts.

Pirmajos mērījumos salīdzini ar dastu un mērlenti — LiDAR precizitāte mežā vēl jāpārbauda.

## Faili
| Fails | Saturs |
|---|---|
| `index.html` | lapas struktūra |
| `style.css` | izskats |
| `app.js` | kamera, sensori, zīmēšana, skaitīšana, saglabāšana, eksports |
| `calc.js` | formulas (BAF, leņķi, slīpums, sastāvs, statistika) |
| `sw.js`, `manifest.webmanifest`, `icons/` | bezsaistes darbība un instalēšana |
| `ios/` | iOS lietotne (Swift, ARKit): `Basal.swift` / `BasalViews.swift` šķērslaukums un prizma, `Measurer.swift` koku mērīšana, `Depth.swift` LiDAR dati un stumbra šķēlums, `Geometry.swift` riņķa fits, `App.swift` ekrāni |

Pēc failu izmaiņām `sw.js` palielini `CACHE` versiju, lai telefons ielādētu jauno versiju.
