// Рендер рилса: Chrome снимает кадр за кадром, ffmpeg склеивает в MP4.
// Запуск: node docs/reel/render.mjs [кадр_в_секундах для превью]
import { createRequire } from 'module';
import { spawn, execSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const require = createRequire(execSync('npm root -g').toString().trim() + '/');
const { chromium } = require('playwright');
const dir = path.dirname(fileURLToPath(import.meta.url));
const FPS = 30;

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1080, height: 1920 } });
// длительности реплик из tts.py → сцены подстраиваются под голос
// вариант (classic|goth) — из переменной окружения VARIANT
const variant = process.env.VARIANT || 'classic';
const voiceFile = path.join(dir, `voice-${variant}.json`);
await page.addInitScript(`window.THEME = ${JSON.stringify(variant)};`);
if (fs.existsSync(voiceFile)) await page.addInitScript(`window.VOICE = ${fs.readFileSync(voiceFile, 'utf8')};`);
await page.goto('file://' + path.join(dir, 'reel.html'));
await page.evaluate(() => document.fonts.ready);
// таймлайн событий для mix.py
fs.writeFileSync(path.join(dir, `timeline-${variant}.json`), JSON.stringify(await page.evaluate(() => TIMELINE), null, 1));

const preview = process.argv.slice(2).map(Number);
if (preview.length) {
  for (const t of preview) {
    await page.evaluate(t => render(t), t);
    await page.screenshot({ path: path.join(dir, `preview-${variant}-${t}.png`) });
  }
} else {
  const total = Math.round((await page.evaluate(() => DURATION)) * FPS);
  const out = path.join(dir, `video-${variant}.mp4`);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-i', '-',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', variant === 'goth' ? '26' : '18', '-preset', 'medium', '-movflags', '+faststart', out],
    { stdio: ['pipe', 'ignore', 'inherit'] });
  for (let i = 0; i < total; i++) {
    await page.evaluate(t => render(t), i / FPS);
    ff.stdin.write(await page.screenshot({ type: 'jpeg', quality: 95 }));
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log('готово:', out, total, 'кадров');
}
await browser.close();
