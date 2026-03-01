import { writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface PhProduct {
  name: string;
  tagline: string;
  votes: number;
  url: string;
}

const RELEVANT_KEYWORDS = ["ai", "crypto", "defi", "trading", "agent", "llm", "blockchain", "bot", "automation"];

export async function fetchPH(): Promise<PhProduct[]> {
  try {
    const jinaUrl = "https://r.jina.ai/https://www.producthunt.com";
    console.log("  Fetching Product Hunt via Jina Reader...");

    const response = await fetch(jinaUrl, {
      headers: { Accept: "text/plain" },
      signal: AbortSignal.timeout(15000),
    });

    if (!response.ok) throw new Error(`Jina HTTP ${response.status}`);

    const markdown = await response.text();
    const truncated = markdown.slice(0, 12000); // Stay within token budget

    const client = new Anthropic();
    const message = await client.messages.create({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1024,
      messages: [
        {
          role: "user",
          content: `从以下 Product Hunt 页面内容中提取今日 top 产品，筛选与 AI、crypto、DeFi、trading、agent、LLM、blockchain、bot 相关的产品。

返回 JSON 数组，每条包含：
- name: 产品名称
- tagline: 简短描述
- votes: 点赞数（数字，没有则为 0）
- url: 产品链接

只返回 JSON 数组，不要其他内容。如果没有相关产品返回空数组 []。

页面内容：
${truncated}`,
        },
      ],
    });

    const text = message.content[0].type === "text" ? message.content[0].text : "[]";
    const jsonMatch = text.match(/\[[\s\S]*\]/);
    const products: PhProduct[] = jsonMatch ? JSON.parse(jsonMatch[0]) : [];

    const outputPath = join(__dirname, "raw", "ph.json");
    mkdirSync(join(__dirname, "raw"), { recursive: true });
    writeFileSync(outputPath, JSON.stringify(products, null, 2));
    console.log(`PH data saved → ${products.length} relevant products`);

    return products;
  } catch (err) {
    console.warn("  ⚠ PH fetch failed:", (err as Error).message);
    const outputPath = join(__dirname, "raw", "ph.json");
    mkdirSync(join(__dirname, "raw"), { recursive: true });
    writeFileSync(outputPath, "[]");
    return [];
  }
}
