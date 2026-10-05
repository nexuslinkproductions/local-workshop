#!/usr/bin/env node
// mockcheck.mjs - layout-quality gate for static HTML mocks.
//
// Playwright import: playwright is installed globally via mise
// (~/.local/share/mise/installs/npm-playwright/latest/node_modules/playwright).
// Node ESM does not resolve global packages, so we import by absolute path.
// Chromium: playwright's own chromium is not downloaded; we launch the system
// chromium at /usr/bin/chromium via executablePath.
//
// Usage: node mockcheck.mjs <folder>
//   Loads every *.html in <folder> at its viewport size (data-size="WxH" on
//   <html> if present, else body/html computed size, else defaults:
//   dp1 2560x1440, others 1920x1200), waits for fonts, then runs:
//     1. overlapping text (different elements, >2px intersection both axes)
//     2. clipped text (rect outside overflow hidden/clip ancestor, or
//        scrollWidth > clientWidth+1 with overflow hidden and no ellipsis)
//     3. text outside the viewport
//     4. contrast < 4.5:1 for font-size < 18px (warnings only; gradient or
//        image backgrounds are reported as UNKNOWN)
//     5. box overlap between visible card/panel/tile surfaces (non-transparent
//        background, border, or box-shadow; area >= 2000 px^2; not ancestor/
//        descendant; not position:fixed full-viewport backdrops over 60% of
//        the viewport; border-box intersection > 4px both axes; either element
//        may carry data-overlap-ok to opt out)
//     6. required elements on dp1.html: a visible #knot/.knot >= 200x200 px,
//        and a /reactor/ element whose box aspect ratio is 0.9..1.1 when it
//        is circular (border-radius >= 45% or contains an svg circle)
//     7. viewport fidelity: document scrollWidth/scrollHeight must not exceed
//        the viewport by more than 1px
//   Screenshots land in <folder>/_check/<page>.png.
//   Exit 0 only if checks 1-3 and 5-7 have zero offenders on every page.

import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire('/home/nexuslink/.local/share/mise/installs/npm-playwright/latest/node_modules/');
const { chromium } = require('playwright');

const CHROMIUM_PATH = '/usr/bin/chromium';
const MAX_OFFENDERS = 20;

const folder = process.argv[2];
if (!folder) {
  console.error('usage: node mockcheck.mjs <folder>');
  process.exit(2);
}
const root = path.resolve(folder);
if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
  console.error(`not a directory: ${root}`);
  process.exit(2);
}

const pages = fs.readdirSync(root).filter(f => f.endsWith('.html')).sort();
if (pages.length === 0) {
  console.error(`no *.html files in ${root}`);
  process.exit(2);
}

const checkDir = path.join(root, '_check');
fs.mkdirSync(checkDir, { recursive: true });

const IN_PAGE_SCRIPT = `(vp) => {
  const VW = vp.width, VH = vp.height;
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'BR', 'HEAD', 'META', 'LINK', 'TITLE']);

  function isVisible(el) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility !== 'visible') return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function selectorPath(el) {
    const parts = [];
    let cur = el;
    while (cur && cur.nodeType === 1 && cur.tagName !== 'HTML') {
      let part = cur.tagName.toLowerCase();
      if (cur.id) { part += '#' + cur.id; parts.unshift(part); break; }
      if (cur.classList.length) part += '.' + [...cur.classList].join('.');
      const parent = cur.parentElement;
      if (parent) {
        const same = [...parent.children].filter(c => c.tagName === cur.tagName);
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(cur) + 1) + ')';
      }
      parts.unshift(part);
      cur = parent;
    }
    return parts.join(' > ');
  }

  function isAriaHiddenDecoration(el) {
    for (let cur = el; cur; cur = cur.parentElement) {
      if (cur.getAttribute && cur.getAttribute('aria-hidden') === 'true') {
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        if (r.width === 0 || r.height === 0) return true;
        if (parseFloat(cs.fontSize) < 4) return true;
      }
    }
    return false;
  }

  function effectiveOpacity(el) {
    let op = 1;
    for (let cur = el; cur; cur = cur.parentElement) {
      op *= parseFloat(getComputedStyle(cur).opacity);
    }
    return op;
  }

  const items = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
  let el;
  while ((el = walker.nextNode())) {
    if (SKIP.has(el.tagName)) continue;
    let hasOwnText = false;
    for (const child of el.childNodes) {
      if (child.nodeType === 3 && child.textContent.trim().length > 0) { hasOwnText = true; break; }
    }
    if (!hasOwnText) continue;
    if (!isVisible(el)) continue;
    const opacity = effectiveOpacity(el);
    if (opacity < 0.15) continue;
    if (isAriaHiddenDecoration(el)) continue;
    const rects = [];
    for (const child of el.childNodes) {
      if (child.nodeType !== 3 || !child.textContent.trim()) continue;
      const range = document.createRange();
      range.selectNodeContents(child);
      for (const r of range.getClientRects()) {
        if (r.width > 0.5 && r.height > 0.5) {
          rects.push({ x: r.x, y: r.y, w: r.width, h: r.height });
        }
      }
      range.detach();
    }
    if (rects.length === 0) continue;
    const cs = getComputedStyle(el);
    items.push({
      el,
      sel: selectorPath(el),
      text: el.textContent.trim().replace(/\\s+/g, ' ').slice(0, 60),
      rects,
      fontSize: parseFloat(cs.fontSize),
      color: cs.color,
      opacity
    });
  }

  // 1. overlapping text (reported once per element pair, worst intersection)
  const overlaps = [];
  const overlapSeen = new Set();
  const isAncestor = (a, b) => a.el.contains(b.el) || b.el.contains(a.el);
  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      const A = items[i], B = items[j];
      if (isAncestor(A, B)) continue;
      let worst = null;
      for (const ra of A.rects) {
        for (const rb of B.rects) {
          const ix = Math.min(ra.x + ra.w, rb.x + rb.w) - Math.max(ra.x, rb.x);
          const iy = Math.min(ra.y + ra.h, rb.y + rb.h) - Math.max(ra.y, rb.y);
          if (ix > 2 && iy > 2 && (!worst || ix * iy > worst.area)) {
            worst = { area: ix * iy, ra, rb, ix, iy };
          }
        }
      }
      if (worst) {
        const key = i + '|' + j;
        if (!overlapSeen.has(key)) {
          overlapSeen.add(key);
          overlaps.push({
            a: { sel: A.sel, text: A.text, rect: worst.ra },
            b: { sel: B.sel, text: B.text, rect: worst.rb },
            intersection: { w: +worst.ix.toFixed(1), h: +worst.iy.toFixed(1) }
          });
        }
      }
    }
  }

  // 2. clipped text
  const clipped = [];
  const clippedSeen = new Set();
  for (const item of items) {
    for (const rect of item.rects) {
      for (let anc = item.el.parentElement; anc; anc = anc.parentElement) {
        const cs = getComputedStyle(anc);
        if (cs.overflow === 'hidden' || cs.overflow === 'clip' ||
            cs.overflowX === 'hidden' || cs.overflowX === 'clip' ||
            cs.overflowY === 'hidden' || cs.overflowY === 'clip') {
          const ar = anc.getBoundingClientRect();
          const out =
            rect.x < ar.x - 1 || rect.y < ar.y - 1 ||
            rect.x + rect.w > ar.x + ar.width + 1 ||
            rect.y + rect.h > ar.y + ar.height + 1;
          if (out) {
            const key = item.sel + '|' + Math.round(rect.x) + ',' + Math.round(rect.y);
            if (!clippedSeen.has(key)) {
              clippedSeen.add(key);
              clipped.push({
                sel: item.sel, text: item.text, rect,
                clipAncestor: selectorPath(anc),
                ancestorRect: { x: ar.x, y: ar.y, w: ar.width, h: ar.height }
              });
            }
          }
          break; // nearest clipping ancestor only
        }
      }
    }
    const cs = getComputedStyle(item.el);
    if ((cs.overflow === 'hidden' || cs.overflowX === 'hidden') &&
        cs.textOverflow !== 'ellipsis' &&
        item.el.scrollWidth > item.el.clientWidth + 1) {
      const key = 'scroll|' + item.sel;
      if (!clippedSeen.has(key)) {
        clippedSeen.add(key);
        clipped.push({
          sel: item.sel, text: item.text, rect: item.rects[0],
          scrollWidth: item.el.scrollWidth, clientWidth: item.el.clientWidth
        });
      }
    }
  }

  // 3. out of viewport
  const outOfVp = [];
  const ovpSeen = new Set();
  for (const item of items) {
    for (const rect of item.rects) {
      if (rect.x < -1 || rect.y < -1 || rect.x + rect.w > VW + 1 || rect.y + rect.h > VH + 1) {
        const key = item.sel + '|' + Math.round(rect.x) + ',' + Math.round(rect.y);
        if (!ovpSeen.has(key)) {
          ovpSeen.add(key);
          outOfVp.push({ sel: item.sel, text: item.text, rect });
        }
      }
    }
  }

  // 4. contrast
  function parseColor(str) {
    const m = str.match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    const parts = m[1].split(',').map(s => parseFloat(s));
    return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
  }
  function luminance({ r, g, b }) {
    const f = c => {
      c /= 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  }
  const contrast = [];
  const contrastSeen = new Set();
  for (const item of items) {
    if (item.fontSize >= 18) continue;
    let bg = null, unknown = false;
    for (let anc = item.el; anc; anc = anc.parentElement) {
      const cs = getComputedStyle(anc);
      const c = parseColor(cs.backgroundColor);
      if (c && c.a >= 0.99) { bg = c; break; }
      if (c && c.a > 0) { bg = c; break; }
      if (cs.backgroundImage && cs.backgroundImage !== 'none') { unknown = true; break; }
    }
    if (!unknown && !bg) {
      const bodyBg = parseColor(getComputedStyle(document.body).backgroundColor);
      if (bodyBg && bodyBg.a > 0) bg = bodyBg; else unknown = true;
    }
    const fg = parseColor(item.color);
    const key = item.sel;
    if (contrastSeen.has(key)) continue;
    contrastSeen.add(key);
    if (unknown || !fg) {
      contrast.push({ sel: item.sel, text: item.text, status: 'UNKNOWN', fontSize: item.fontSize });
      continue;
    }
    const L1 = luminance(fg), L2 = luminance(bg);
    const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
    if (ratio < 4.5) {
      contrast.push({
        sel: item.sel, text: item.text, status: 'FAIL',
        ratio: +ratio.toFixed(2), fontSize: item.fontSize,
        fg: item.color, bg: 'rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ')'
      });
    }
  }

  // 5. box overlap between card/panel/tile surfaces
  function hasSurface(el) {
    const cs = getComputedStyle(el);
    const bg = cs.backgroundColor.match(/rgba?\\(([^)]+)\\)/);
    if (bg) {
      const a = bg[1].split(',').map(s => parseFloat(s));
      if (a.length > 3 && a[3] > 0) return true;
      if (a.length === 3) return true;
    }
    if (cs.backgroundImage && cs.backgroundImage !== 'none') return true;
    const bw = [cs.borderTopWidth, cs.borderRightWidth, cs.borderBottomWidth, cs.borderLeftWidth]
      .map(parseFloat);
    const bs = [cs.borderTopStyle, cs.borderRightStyle, cs.borderBottomStyle, cs.borderLeftStyle];
    for (let i = 0; i < 4; i++) {
      if (bw[i] > 0 && bs[i] !== 'none' && bs[i] !== 'hidden') return true;
    }
    if (cs.boxShadow && cs.boxShadow !== 'none') return true;
    return false;
  }

  const surfaces = [];
  {
    const walker2 = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    let el2;
    while ((el2 = walker2.nextNode())) {
      if (SKIP.has(el2.tagName)) continue;
      if (!isVisible(el2)) continue;
      if (effectiveOpacity(el2) < 0.15) continue;
      if (!hasSurface(el2)) continue;
      const r = el2.getBoundingClientRect();
      const area = r.width * r.height;
      if (area < 2000) continue;
      const cs = getComputedStyle(el2);
      if ((cs.position === 'fixed' || cs.position === 'absolute') && area > 0.6 * VW * VH) continue;
      surfaces.push({ el: el2, sel: selectorPath(el2), rect: r, area });
    }
  }

  const boxOverlaps = [];
  const boxSeen = new Set();
  for (let i = 0; i < surfaces.length; i++) {
    for (let j = i + 1; j < surfaces.length; j++) {
      const A = surfaces[i], B = surfaces[j];
      if (A.el.contains(B.el) || B.el.contains(A.el)) continue;
      if (A.el.hasAttribute('data-overlap-ok') || B.el.hasAttribute('data-overlap-ok')) continue;
      const contains = (P, Q) =>
        P.rect.x >= Q.rect.x - 1 && P.rect.y >= Q.rect.y - 1 &&
        P.rect.x + P.rect.width <= Q.rect.x + Q.rect.width + 1 &&
        P.rect.y + P.rect.height <= Q.rect.y + Q.rect.height + 1;
      if (contains(A, B) || contains(B, A)) continue;
      const ix = Math.min(A.rect.x + A.rect.width, B.rect.x + B.rect.width) - Math.max(A.rect.x, B.rect.x);
      const iy = Math.min(A.rect.y + A.rect.height, B.rect.y + B.rect.height) - Math.max(A.rect.y, B.rect.y);
      if (ix > 4 && iy > 4) {
        const key = i + '|' + j;
        if (!boxSeen.has(key)) {
          boxSeen.add(key);
          boxOverlaps.push({
            a: { sel: A.sel, rect: { x: A.rect.x, y: A.rect.y, w: A.rect.width, h: A.rect.height } },
            b: { sel: B.sel, rect: { x: B.rect.x, y: B.rect.y, w: B.rect.width, h: B.rect.height } },
            intersection: { w: +ix.toFixed(1), h: +iy.toFixed(1) }
          });
        }
      }
    }
  }

  // 6. required elements (dp1 pages only)
  const required = [];
  function isOccluded(el) {
    // pointer-events:none artwork is invisible to elementsFromPoint; force it
    // hit-testable while sampling, then restore.
    const forced = [];
    for (let cur = el; cur; cur = cur.parentElement) {
      const cs = getComputedStyle(cur);
      if (cs.pointerEvents === 'none') {
        forced.push([cur, cur.style.pointerEvents]);
        cur.style.pointerEvents = 'auto';
      }
    }
    el.querySelectorAll('*').forEach(d => {
      const cs = getComputedStyle(d);
      if (cs.pointerEvents === 'none') {
        forced.push([d, d.style.pointerEvents]);
        d.style.pointerEvents = 'auto';
      }
    });
    const r = el.getBoundingClientRect();
    let reachable = 0, total = 0;
    for (let fy = 0.05; fy < 1; fy += 0.1) {
      for (let fx = 0.05; fx < 1; fx += 0.1) {
        const x = r.x + r.width * fx, y = r.y + r.height * fy;
        if (x < 0 || y < 0 || x > VW || y > VH) continue;
        total++;
        const stack = document.elementsFromPoint(x, y);
        if (stack.some(e => e === el || el.contains(e))) reachable++;
      }
    }
    for (const [node, prev] of forced) node.style.pointerEvents = prev;
    return total > 0 && reachable === 0;
  }
  if (vp.page === 'dp1') {
    const knotEl = document.querySelector('#knot, .knot, [id*="knot" i], [class*="knot" i]');
    if (!knotEl) {
      required.push({ check: 'knot', detail: 'no element with id or class matching /knot/' });
    } else {
      const r = knotEl.getBoundingClientRect();
      const cs = getComputedStyle(knotEl);
      const vis = cs.display !== 'none' && cs.visibility === 'visible' && r.width > 0 && r.height > 0;
      if (!vis) {
        required.push({ check: 'knot', detail: 'knot element not visible' });
      } else if (r.width < 200 || r.height < 200) {
        required.push({ check: 'knot', detail: 'knot bounding box ' + r.width.toFixed(0) + 'x' + r.height.toFixed(0) + ' < 200x200' });
      } else if (isOccluded(knotEl)) {
        required.push({ check: 'knot', detail: 'knot element fully covered by other elements' });
      }
    }

    const reactorEl = document.querySelector('#reactor, .reactor, [id*="reactor" i], [class*="reactor" i]');
    if (!reactorEl) {
      required.push({ check: 'reactor', detail: 'no element with id or class matching /reactor/' });
    } else {
      const r = reactorEl.getBoundingClientRect();
      const cs = getComputedStyle(reactorEl);
      const br = parseFloat(cs.borderRadius);
      const isCircular = br >= 45 || reactorEl.querySelector('svg circle') !== null;
      if (isCircular) {
        const ratio = r.width / r.height;
        if (ratio < 0.9 || ratio > 1.1) {
          required.push({ check: 'reactor', detail: 'reactor not circular: aspect ratio ' + ratio.toFixed(2) + ' (' + r.width.toFixed(0) + 'x' + r.height.toFixed(0) + ')' });
        }
      }
    }
  }

  return { overlaps, clipped, outOfVp, contrast, boxOverlaps, required, textItems: items.length };
}`;

function fmtRect(r) {
  return `[${r.x.toFixed(0)},${r.y.toFixed(0)} ${r.w.toFixed(0)}x${r.h.toFixed(0)}]`;
}

const browser = await chromium.launch({ executablePath: CHROMIUM_PATH });
let anyFail = false;

for (const file of pages) {
  const filePath = path.join(root, file);
  const probe = await browser.newPage();
  await probe.goto('file://' + filePath);
  await probe.evaluate(() => document.fonts.ready);
  const size = await probe.evaluate(() => {
    const ds = document.documentElement.getAttribute('data-size');
    if (ds) {
      const m = ds.match(/^(\d+)\s*x\s*(\d+)$/i);
      if (m) return { width: +m[1], height: +m[2], source: 'data-size' };
    }
    const bw = document.body ? Math.round(document.body.getBoundingClientRect().width) : 0;
    const bh = document.body ? Math.round(document.body.getBoundingClientRect().height) : 0;
    const hw = Math.round(document.documentElement.getBoundingClientRect().width);
    const hh = Math.round(document.documentElement.getBoundingClientRect().height);
    const width = Math.max(bw, hw), height = Math.max(bh, hh);
    if (width >= 320 && height >= 240) return { width, height, source: 'computed' };
    return null;
  });
  await probe.close();

  const base = path.basename(file, '.html').toLowerCase();
  const def = base.startsWith('dp1') ? { width: 2560, height: 1440 } : { width: 1920, height: 1200 };
  let vp = def, vpSource = 'default';
  if (size) {
    if (size.source === 'data-size') {
      vp = { width: size.width, height: size.height };
      vpSource = 'data-size';
    } else if (size.width >= def.width && size.height >= def.height) {
      vp = { width: size.width, height: size.height };
      vpSource = 'computed';
    }
  }
  vp.page = base.startsWith('dp1') ? 'dp1' : base;

  const page = await browser.newPage({ viewport: vp });
  await page.goto('file://' + filePath);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(150);

  const result = await page.evaluate(new Function('vp', `return (${IN_PAGE_SCRIPT})(vp)`), vp);

  // 7. viewport fidelity
  const scroll = await page.evaluate(() => ({
    sw: document.documentElement.scrollWidth,
    sh: document.documentElement.scrollHeight
  }));
  const overflowX = scroll.sw > vp.width + 1;
  const overflowY = scroll.sh > vp.height + 1;
  const vpFail = overflowX || overflowY;

  const shot = path.join(checkDir, path.basename(file, '.html') + '.png');
  await page.screenshot({ path: shot, fullPage: false });
  await page.close();

  const failCount = result.overlaps.length + result.clipped.length + result.outOfVp.length +
    result.boxOverlaps.length + result.required.length + (vpFail ? 1 : 0);
  if (failCount > 0) anyFail = true;

  console.log(`\n=== ${file} === viewport ${vp.width}x${vp.height} (${vpSource}) · ${result.textItems} text items`);
  console.log(`  overlap: ${result.overlaps.length}  clipped: ${result.clipped.length}  out-of-viewport: ${result.outOfVp.length}  contrast-warn: ${result.contrast.length}  box-overlap: ${result.boxOverlaps.length}  required: ${result.required.length}  viewport-overflow: ${vpFail ? 1 : 0}`);
  console.log(`  screenshot: ${shot}`);

  const show = (label, list, fmt) => {
    for (const o of list.slice(0, MAX_OFFENDERS)) console.log(`    [${label}] ${fmt(o)}`);
    if (list.length > MAX_OFFENDERS) console.log(`    [${label}] ... and ${list.length - MAX_OFFENDERS} more`);
  };
  show('overlap', result.overlaps, o =>
    `${o.a.sel} "${o.a.text}" ${fmtRect(o.a.rect)}  X  ${o.b.sel} "${o.b.text}" ${fmtRect(o.b.rect)}  (${o.intersection.w}x${o.intersection.h})`);
  show('clip', result.clipped, o =>
    o.scrollWidth !== undefined
      ? `${o.sel} "${o.text}" scrollWidth ${o.scrollWidth} > clientWidth ${o.clientWidth}`
      : `${o.sel} "${o.text}" ${fmtRect(o.rect)} outside ${o.clipAncestor} ${fmtRect(o.ancestorRect)}`);
  show('viewport', result.outOfVp, o => `${o.sel} "${o.text}" ${fmtRect(o.rect)}`);
  show('contrast', result.contrast, o =>
    o.status === 'UNKNOWN'
      ? `${o.sel} "${o.text}" ${o.fontSize}px UNKNOWN (gradient/image background)`
      : `${o.sel} "${o.text}" ${o.fontSize}px ratio ${o.ratio} fg ${o.fg} bg ${o.bg}`);
  show('box-overlap', result.boxOverlaps, o =>
    `${o.a.sel} ${fmtRect(o.a.rect)}  X  ${o.b.sel} ${fmtRect(o.b.rect)}  (${o.intersection.w}x${o.intersection.h})`);
  show('required', result.required, o => `${o.check}: ${o.detail}`);
  if (vpFail) {
    console.log(`    [viewport] scroll ${scroll.sw}x${scroll.sh} exceeds viewport ${vp.width}x${vp.height}${overflowX ? ' (width)' : ''}${overflowY ? ' (height)' : ''}`);
  }
}

await browser.close();
console.log(`\nRESULT: ${anyFail ? 'FAIL' : 'PASS'}`);
process.exit(anyFail ? 1 : 0);
