#!/usr/bin/env bun
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { loadConfig } from "./load-config.js";
import { fetchGithub } from "./fetch-github.js";
import { fetchPH } from "./fetch-ph.js";
import { synthesize } from "./synthesize.js";
import { sendTelegram } from "./send-telegram.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARCHIVE_PATH = join(__dirname, "archive.json");
const MAX_ARCHIVE_ENTRIES = 30;

interface ArchiveEntry {
  date: string;
  markdown: string;
  githubCount: number;
  phCount: number;
}

function loadArchive(): ArchiveEntry[] {
  if (!existsSync(ARCHIVE_PATH)) return [];
  try {
    return JSON.parse(readFileSync(ARCHIVE_PATH, "utf-8")) as ArchiveEntry[];
  } catch {
    return [];
  }
}

function saveArchive(entries: ArchiveEntry[]): void {
  // Keep only the most recent MAX_ARCHIVE_ENTRIES (FIFO)
  const trimmed = entries.slice(-MAX_ARCHIVE_ENTRIES);
  writeFileSync(ARCHIVE_PATH, JSON.stringify(trimmed, null, 2));
}

async function step<T>(name: string, fn: () => Promise<T>, fallback: T): Promise<T> {
  console.log(`\n[${name}]`);
  try {
    return await fn();
  } catch (err) {
    console.error(`  ✗ ${name} failed:`, (err as Error).message);
    return fallback;
  }
}

async function main() {
  const startTime = Date.now();
  console.log("=== CEO Intel Pipeline ===");
  console.log(`Started: ${new Date().toISOString()}`);

  // Step 1: Load config (with dynamic competitors API)
  const config = await step("load-config", loadConfig, {
    github_repos: ["hummingbot/hummingbot", "anthropics/claude-code"],
    competitors_api_url: "",
    telegram_chat_id: process.env.TELEGRAM_CHAT_ID ?? "",
  });

  // Step 2 & 3: Fetch data (GitHub + PH in parallel)
  const [githubData, phData] = await Promise.all([
    step("fetch-github", () => fetchGithub(config.github_repos), []),
    step("fetch-ph", fetchPH, []),
  ]);

  // Step 4: Synthesize
  const brief = await step("synthesize", synthesize, "合成失败");

  // Step 5: Send Telegram
  await step("send-telegram", () => sendTelegram(brief), undefined);

  // Step 6: Update archive
  const today = new Date().toISOString().slice(0, 10);
  const archive = loadArchive();
  const existingIdx = archive.findIndex((e) => e.date === today);
  const entry: ArchiveEntry = {
    date: today,
    markdown: brief,
    githubCount: githubData.length,
    phCount: phData.length,
  };

  if (existingIdx >= 0) {
    archive[existingIdx] = entry; // Overwrite today's entry if re-run
  } else {
    archive.push(entry);
  }

  saveArchive(archive);
  console.log(`\n✓ Archive updated (${archive.length} entries)`);

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\n=== Done in ${elapsed}s ===`);
}

main();
