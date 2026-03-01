import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import type { GithubRepoData } from "./fetch-github.js";
import type { PhProduct } from "./fetch-ph.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10);
}

function readJsonSafe<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch {
    return fallback;
  }
}

export async function synthesize(): Promise<string> {
  const githubData = readJsonSafe<GithubRepoData[]>(
    join(__dirname, "raw", "github.json"),
    []
  );
  const phData = readJsonSafe<PhProduct[]>(
    join(__dirname, "raw", "ph.json"),
    []
  );

  const githubSummary = githubData
    .map(
      (r) =>
        `${r.repo}: ⭐${r.stars.toLocaleString()}` +
        (r.latestRelease ? ` | 最新: ${r.latestRelease.tag} (${r.latestRelease.date})` : "") +
        (r.recentIssues.length ? ` | Issues: ${r.recentIssues.slice(0, 2).join("; ")}` : "")
    )
    .join("\n");

  const phSummary =
    phData.length > 0
      ? phData
          .slice(0, 6)
          .map((p) => `${p.name} (▲${p.votes}): ${p.tagline}`)
          .join("\n")
      : "今日无相关产品";

  const client = new Anthropic();
  const message = await client.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 800,
    system: `你是 Donut AI 的竞品情报分析师。请将以下原始数据合成为 CEO 每日简报，要求：
- 全程中文
- 使用 emoji 分节
- 总字数 < 400 字
- 三个固定 section：🏆 GitHub 竞品动态 / 🔥 PH 今日热榜 / 💡 D0 相关信号
- 每个 section 最多 4 条 bullet（用 • 开头）
- D0 相关信号：从数据中提炼对 Donut/D0 产品有参考价值的信号或机会
- 语气简洁、数据驱动，不要废话`,
    messages: [
      {
        role: "user",
        content: `GitHub 数据：\n${githubSummary}\n\nProduct Hunt 数据：\n${phSummary}`,
      },
    ],
  });

  const brief =
    message.content[0].type === "text" ? message.content[0].text : "合成失败";

  const date = todayUTC();
  const outputDir = join(__dirname, "synthesized");
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(join(outputDir, `${date}.md`), brief);
  console.log(`Brief synthesized → synthesized/${date}.md`);

  return brief;
}
