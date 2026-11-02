#!/usr/bin/env node
/* Render the DSH Mobile promo timeline to PNG frames. */
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const fps = Number(opt('fps', 30));
const dsf = Number(opt('scale', 2));
const times = opt('times', '');           // "1.2,3.4" for stills
const outDir = path.resolve(opt('out', 'frames'));
const only = opt('only', 'all');

const exe = process.env.CHROMIUM_PATH;   // optional: point at a specific Chromium build

fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch(exe ? { executablePath: exe } : {});
const context = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  deviceScaleFactor: dsf,
});
const page = await context.newPage();
const url = 'file://' + path.resolve('index.html');
await page.goto(url, { waitUntil: 'load' });
await page.waitForFunction(() => window.__ready === true, null, { timeout: 20000 });
const duration = await page.evaluate(() => window.DURATION);

if (times) {
  for (const s of times.split(',').map(Number)) {
    await page.evaluate((t) => window.seek(t), s);
    await page.waitForTimeout(40);
    const f = path.join(outDir, `still-${s.toFixed(2)}.png`);
    await page.screenshot({ path: f });
    console.log(f);
  }
} else {
  const total = Math.round(duration * fps);
  const start = Number(opt('start', 0));
  const end = Number(opt('end', duration));
  const i0 = Math.round(start * fps);
  const i1 = Math.round(end * fps);
  console.log(`duration ${duration}s · ${i1 - i0} frames @${fps}fps`);
  const t0 = Date.now();
  for (let i = i0; i < i1; i++) {
    const t = i / fps;
    await page.evaluate((tt) => window.seek(tt), t);
    const f = path.join(outDir, `f${String(i).padStart(5, '0')}.png`);
    await page.screenshot({ path: f });
    if (i % 60 === 0) {
      const el = ((Date.now() - t0) / 1000).toFixed(1);
      console.log(`frame ${i}/${i1} · ${el}s`);
    }
  }
}
await browser.close();
