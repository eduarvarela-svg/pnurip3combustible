// Actualiza precios.json con los precios vigentes de los combustibles en Honduras.
// Revisa varias fuentes públicas, se queda con la semana más reciente y valida los
// números antes de guardar. Si no encuentra nada confiable, conserva los precios anteriores.
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const ARCHIVO = new URL('../precios.json', import.meta.url);
const CIUDADES = ['Tegucigalpa', 'San Pedro Sula'];
const MESES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
const COMBUSTIBLES = {
  super:         { re: /s[uú]per/i,                                           min: 80, max: 300 },
  regular:       { re: /regular/i,                                            min: 80, max: 300 },
  diesel:        { re: /di[eé]sel/i,                                          min: 80, max: 300 },
  kerosene:      { re: /keros[eé]n[ea]?|queroseno|kerosina/i,                 min: 80, max: 300 },
  glp_vehicular: { re: /(?:GLP|LPG|gas licuado)[^0-9]{0,25}?(?:de uso )?vehicular/i, min: 20, max: 120 },
};
const PAGINAS_FIJAS = [
  'https://www.hondurashoy.hn/combustibles/',
  'https://proceso.hn/tabla-de-precios-combustibles-2026/',
];
const BUSQUEDAS = [
  'precios combustibles Honduras a partir del lunes',
  'precios de los combustibles Honduras lunes tunota',
  'tabla precios combustibles Honduras hoy',
];

// ---------- utilidades ----------
export function htmlATexto(html) {
  return String(html)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<(br|\/p|\/li|\/tr|\/h\d|\/div|\/td|\/th)[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#0?39;/g, "'")
    .replace(/&aacute;/g, 'á').replace(/&eacute;/g, 'é').replace(/&iacute;/g, 'í').replace(/&oacute;/g, 'ó').replace(/&uacute;/g, 'ú').replace(/&ntilde;/g, 'ñ')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/[ \t\r]+/g, ' ')
    .replace(/\n\s*/g, '\n');
}
const iso = d => d.toISOString().slice(0, 10);
function sumarDias(isoStr, n) { const d = new Date(isoStr + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return iso(d); }
function esLunes(isoStr) { return new Date(isoStr + 'T12:00:00Z').getUTCDay() === 1; }
const num = s => Number(String(s).replace(/,/g, ''));

// Fecha de vigencia: "a partir del lunes 28 de septiembre", "vigentes desde el 21 de septiembre de 2026"
export function buscarVigencia(texto, url = '', hoy = new Date()) {
  const candidatos = [];
  const re = /(?:lunes|a partir del?|desde el|vigentes? (?:desde|a partir) del?)\s+(?:lunes\s+)?(\d{1,2})\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)(?:\s+(?:de|del)\s+(\d{4}))?/gi;
  let m;
  while ((m = re.exec(texto))) {
    const mes = MESES.indexOf(m[2].toLowerCase().replace('setiembre', 'septiembre'));
    let anio = m[3] ? Number(m[3]) : hoy.getUTCFullYear();
    let f = new Date(Date.UTC(anio, mes, Number(m[1]), 12));
    if (!m[3] && f - hoy > 60 * 864e5) f = new Date(Date.UTC(anio - 1, mes, Number(m[1]), 12));
    candidatos.push(iso(f));
  }
  const u = String(url).match(/lunes-(\d{1,2})-de-([a-z]+)/i);
  if (u) { const mes = MESES.indexOf(u[2].toLowerCase()); if (mes >= 0) candidatos.push(iso(new Date(Date.UTC(hoy.getUTCFullYear(), mes, Number(u[1]), 12)))); }
  const limite = iso(new Date(hoy.getTime() + 3 * 864e5));
  const validos = candidatos.filter(f => esLunes(f) && f <= limite).sort();
  return validos.length ? validos[validos.length - 1] : null;
}

// Precios de una ciudad dentro del texto
export function preciosDeCiudad(texto, ciudad) {
  const otras = CIUDADES.filter(c => c !== ciudad);
  let mejor = null;
  const reCiudad = new RegExp(ciudad.replace(/ /g, '\\s+'), 'gi');
  let m;
  while ((m = reCiudad.exec(texto))) {
    let fin = Math.min(texto.length, m.index + 1800);
    for (const o of otras) { const j = texto.slice(m.index + 5).search(new RegExp(o.replace(/ /g, '\\s+'), 'i')); if (j >= 0) fin = Math.min(fin, m.index + 5 + j); }
    const seg = texto.slice(m.index, fin);
    const r = {};
    for (const [k, c] of Object.entries(COMBUSTIBLES)) {
      const rx = new RegExp('(?:' + c.re.source + ')[^0-9\\n]{0,60}?(?:\\n[^0-9\\n]{0,30})?L?\\.?\\s*(\\d{2,3}(?:,\\d{3})*\\.\\d{1,2})', 'i');
      const p = seg.match(rx);
      if (!p) continue;
      const precio = num(p[1]);
      if (!(precio >= c.min && precio <= c.max)) continue;
      const despues = seg.slice(p.index + p[0].length, p.index + p[0].length + 90);
      let variacion = 0;
      const v = despues.match(/^[^0-9]{0,40}?(sube|subi[oó]|aumenta|aument[oó]|alza|incremento de|\+|baja|baj[oó]|rebaja|disminuye|reducci[oó]n de|-|−)\s*(?:de\s*)?L?\.?\s*(\d{1,2}\.\d{1,2})/i);
      if (v) variacion = (/baj|rebaj|dismin|reduc|-|−/i.test(v[1]) ? -1 : 1) * num(v[2]);
      r[k] = { precio, var: Math.round(variacion * 100) / 100 };
    }
    const n = Object.keys(r).length;
    if (r.super && r.regular && r.diesel && r.super.precio > r.regular.precio && (!mejor || n > Object.keys(mejor).length)) mejor = r;
  }
  return mejor;
}

export function analizarPagina(html, url, hoy = new Date()) {
  const texto = htmlATexto(html);
  const vigencia = buscarVigencia(texto, url, hoy);
  if (!vigencia) return null;
  const ciudades = {};
  for (const c of CIUDADES) { const p = preciosDeCiudad(texto, c); if (p) ciudades[c] = p; }
  if (!ciudades.Tegucigalpa) return null;
  return { vigencia, ciudades, url };
}

// ---------- red ----------
async function bajar(url) {
  const r = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; URIP-precios/1.0)', 'Accept-Language': 'es-HN,es;q=0.9' }, redirect: 'follow', signal: AbortSignal.timeout(20000) });
  if (!r.ok) throw new Error(r.status + ' ' + url);
  return r.text();
}
async function enlacesDeNoticias() {
  const urls = new Set();
  for (const q of BUSQUEDAS) {
    try {
      const xml = await bajar('https://www.bing.com/news/search?format=rss&q=' + encodeURIComponent(q));
      for (const m of xml.matchAll(/<link>([^<]+)<\/link>/g)) {
        let u = m[1].replace(/&amp;/g, '&');
        const real = u.match(/[?&]url=([^&]+)/); if (real) u = decodeURIComponent(real[1]);
        if (/combustible/i.test(u) && !/bing\.com/i.test(u)) urls.add(u);
      }
    } catch (e) { console.log('Búsqueda sin resultado:', e.message); }
  }
  return [...urls].slice(0, 12);
}

async function main() {
  const hoy = new Date();
  const actual = JSON.parse(await readFile(ARCHIVO, 'utf8').catch(() => '{}'));
  const paginas = [...PAGINAS_FIJAS, ...(await enlacesDeNoticias())];
  const resultados = [];
  for (const url of paginas) {
    try {
      const r = analizarPagina(await bajar(url), url, hoy);
      console.log(r ? `✔ ${url} → vigencia ${r.vigencia}, súper Tegucigalpa L ${r.ciudades.Tegucigalpa.super.precio}` : `· ${url} → sin precios reconocibles`);
      if (r) resultados.push(r);
    } catch (e) { console.log('✖', url, e.message); }
  }
  resultados.sort((a, b) => b.vigencia.localeCompare(a.vigencia) || Object.keys(b.ciudades).length - Object.keys(a.ciudades).length);
  const mejor = resultados[0];
  const ahora = new Date().toISOString();

  if (!mejor || (actual.vigencia && mejor.vigencia < actual.vigencia)) {
    console.log('No se encontraron precios más recientes. Se conservan los de', actual.vigencia);
    if (actual.vigencia && (hoy - new Date(actual.vigencia + 'T12:00:00Z')) > 8 * 864e5) {
      console.error('⚠ Los precios guardados tienen más de una semana. Revise las fuentes o actualice precios.json a mano.');
      process.exitCode = 1;
    }
    return;
  }
  // Si la variación no venía en la noticia, se calcula contra la semana anterior guardada
  for (const [ciudad, tipos] of Object.entries(mejor.ciudades)) {
    for (const [k, v] of Object.entries(tipos)) {
      const prev = actual.ciudades?.[ciudad]?.[k]?.precio;
      if (!v.var && prev && actual.vigencia && actual.vigencia < mejor.vigencia) v.var = Math.round((v.precio - prev) * 100) / 100;
      if (actual.vigencia === mejor.vigencia && actual.ciudades?.[ciudad]?.[k] && !v.var) v.var = actual.ciudades[ciudad][k].var || 0;
    }
  }
  const dominio = new URL(mejor.url).hostname.replace(/^www\./, '');
  const nuevo = {
    vigencia: mejor.vigencia,
    hasta: sumarDias(mejor.vigencia, 6),
    actualizado: ahora,
    fuente: `Secretaría de Energía (vía ${dominio})`,
    ciudades: Object.assign({}, actual.vigencia === mejor.vigencia ? actual.ciudades : {}, mejor.ciudades),
  };
  await writeFile(ARCHIVO, JSON.stringify(nuevo, null, 2) + '\n');
  console.log('precios.json actualizado: vigencia', nuevo.vigencia, '· fuente', dominio);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(e => { console.error(e); process.exitCode = 1; });
}
