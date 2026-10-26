import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const root = fileURLToPath(new URL("..", import.meta.url));
const chrome = process.env.CHROME_PATH || "/usr/local/bin/google-chrome";
const shot = "/opt/cursor/artifacts/download-counts.png";

test("counters render under every Download button and clicks stick", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rx-browser-"));
  const file = join(dir, "c.sqlite");
  const child = startServer(file);
  const browser = await puppeteer.launch({
    executablePath: chrome,
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  try {
    const port = await child.port;
    const page = await browser.newPage();
    await page.setUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15");
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0" });
    await page.waitForSelector(".rx-counts");
    const panels = await page.$$(".rx-counts");
    assert.equal(panels.length, 3, "one counter under each Download button");
    const labels = await page.$$eval(".rx-counts", (nodes) => nodes.map((node) => node.innerText));
    for (const text of labels) {
      assert.match(text, /Windows/);
      assert.match(text, /macOS/);
      assert.match(text, /Linux/);
      assert.match(text, /Android/);
      assert.match(text, /iOS/);
      assert.match(text, /Total/);
    }
    await page.click("a[href='/api/store/download/vortex/darwin-universal'].btn-glow");
    await page.waitForFunction(() => document.querySelector(".rx-counts")?.innerText.includes("Total") && /Total\s+1/.test(document.querySelector(".rx-counts").innerText));
    await page.reload({ waitUntil: "networkidle0" });
    await page.waitForFunction(() => /Total\s+1/.test(document.querySelector(".rx-counts")?.innerText || ""));
    await page.click("a[href='/api/store/download/vortex/darwin-universal'].btn-glow");
    await new Promise((resolve) => setTimeout(resolve, 400));
    const afterSpam = await page.$eval(".rx-counts", (node) => node.innerText);
    assert.match(afterSpam, /Total\s+1/);

    const windows = await browser.newPage();
    await windows.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36");
    await windows.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0" });
    await windows.click("a[href='/api/store/download/rotten-core/windows-amd64']");
    await windows.waitForFunction(() => {
      const card = [...document.querySelectorAll("article")].find((node) => node.innerText.includes("Rotten Core"));
      return /Windows\s+1/.test(card?.innerText || "") && /Total\s+1/.test(card?.innerText || "");
    });

    const linux = await browser.newPage();
    await linux.setUserAgent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36");
    await linux.goto(`http://127.0.0.1:${port}/fixture`, { waitUntil: "networkidle0" });
    await linux.waitForSelector(".rx-counts");
    assert.equal((await linux.$$(".rx-counts")).length, 2);
    await linux.click("a[href='/api/store/download/poison-apple/linux-amd64']");
    await linux.waitForFunction(() => /Linux\s+1/.test(document.body.innerText) && /Total\s+1/.test(document.body.innerText));
    const chipCountBefore = (await linux.$$(".rx-counts")).length;
    await linux.click("a[href='/api/store/download/poison-apple/android']");
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal((await linux.$$(".rx-counts")).length, chipCountBefore);

    await page.bringToFront();
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0" });
    await page.waitForSelector(".rx-counts");
    await mkdir("/opt/cursor/artifacts", { recursive: true });
    await page.screenshot({ path: shot, fullPage: true });
  } finally {
    await browser.close();
    child.kill();
    await rm(dir, { recursive: true, force: true });
  }
});

function startServer(file) {
  const child = spawn(process.execPath, ["src/server.mjs"], {
    cwd: root,
    env: { ...process.env, PORT: "0", COUNTS_DB: file, COUNT_TRUST_PROXY: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let buffer = "";
  const port = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`server did not start: ${buffer}`)), 8000);
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/127\.0\.0\.1:(\d+)/);
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    child.stderr.on("data", (chunk) => {
      buffer += chunk.toString();
    });
  });
  return { port, kill: () => child.kill() };
}
