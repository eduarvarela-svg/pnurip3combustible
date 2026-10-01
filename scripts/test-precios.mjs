import assert from 'node:assert/strict';
import { analizarPagina } from './actualizar-precios.mjs';
const hoy = new Date('2026-09-30T18:00:00Z');

// Estilo noticia (tabla por ciudad con variación)
const nota = `<html><h1>Precios de los combustibles suben a partir del lunes 28 de septiembre en Honduras</h1>
<p>Los nuevos precios entran en vigencia a partir del lunes 28 de septiembre de 2026.</p>
<h2>Tegucigalpa</h2><table><tr><td>Gasolina súper</td><td>L 153.17</td><td>Sube L 4.87</td></tr>
<tr><td>Gasolina regular</td><td>L 135.26</td><td>Sube L 2.45</td></tr><tr><td>Diésel</td><td>L 153.53</td><td>Sube L 2.43</td></tr>
<tr><td>Queroseno</td><td>L 138.39</td><td>Sube L 3.84</td></tr><tr><td>GLP vehicular</td><td>L 51.92</td><td>Sube L 0.83</td></tr>
<tr><td>GLP doméstico (25 lb)</td><td>L 249.62</td><td>Se mantiene</td></tr></table>
<h2>San Pedro Sula</h2><table><tr><td>Gasolina súper</td><td>L 148.69</td><td>Sube L 4.75</td></tr>
<tr><td>Gasolina regular</td><td>L 130.98</td><td>Sube L 2.38</td></tr><tr><td>Diésel</td><td>L 149.20</td><td>Sube L 2.35</td></tr>
<tr><td>Queroseno</td><td>L 133.86</td><td>Sube L 3.70</td></tr><tr><td>GLP vehicular</td><td>L 48.39</td><td>Sube L 0.83</td></tr></table></html>`;
const r = analizarPagina(nota, 'https://www.tunota.com/economia/precios-de-los-combustibles-suben-a-partir-del-lunes-28-de-septiembre-en-honduras-2026-09-27', hoy);
assert.equal(r.vigencia, '2026-09-28');
assert.deepEqual(r.ciudades.Tegucigalpa.super, { precio: 153.17, var: 4.87 });
assert.deepEqual(r.ciudades.Tegucigalpa.glp_vehicular, { precio: 51.92, var: 0.83 });
assert.deepEqual(r.ciudades['San Pedro Sula'].diesel, { precio: 149.2, var: 2.35 });
assert.deepEqual(r.ciudades.Tegucigalpa.kerosene, { precio: 138.39, var: 3.84 });

// Estilo página fija con rebajas
const pag = `<div><p>Precios vigentes desde el 21 de septiembre de 2026.</p><h3>Tegucigalpa</h3>
<div>Súper</div><div>L 148.30 por galón</div><div>Baja L 1.20</div>
<div>Regular</div><div>L 132.81 por galón</div><div>Sube L 2.30</div>
<div>Diésel</div><div>L 151.10 por galón</div><div>Se mantiene</div>
<div>Kerosene</div><div>L 134.55 por galón</div><div>Sube L 4.69</div>
<div>GLP doméstico</div><div>L 249.62 por cilindro 25 lb</div>
<div>GLP vehicular</div><div>L 51.09 por galón</div><div>Sube L 1.15</div></div>`;
const p = analizarPagina(pag, 'https://www.hondurashoy.hn/combustibles/', hoy);
assert.equal(p.vigencia, '2026-09-21');
assert.deepEqual(p.ciudades.Tegucigalpa.super, { precio: 148.3, var: -1.2 });
assert.deepEqual(p.ciudades.Tegucigalpa.diesel, { precio: 151.1, var: 0 });
assert.deepEqual(p.ciudades.Tegucigalpa.glp_vehicular, { precio: 51.09, var: 1.15 });

// Página sin fecha ni precios → se descarta
assert.equal(analizarPagina('<p>Noticias generales</p>', 'https://x.hn', hoy), null);
console.log('Pruebas OK');
