import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10);
}

// MarkdownV2 requires escaping: _ * [ ] ( ) ~ ` > # + - = | { } . !
function escapeMarkdownV2(text: string): string {
  return text.replace(/([_*[\]()~`>#+=|{}.!\\-])/g, "\\$1");
}

export async function sendTelegram(brief: string): Promise<void> {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;

  if (!token || !chatId) {
    console.error("  ✗ TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set");
    return;
  }

  const date = todayUTC();
  const header = `🧠 *CEO Daily Intel · ${date}*\n\n`;
  // Use plain Markdown (not V2) since brief contains emoji and bullets
  const fullMessage = header + brief;

  try {
    const response = await fetch(
      `https://api.telegram.org/bot${token}/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: chatId,
          text: fullMessage,
          parse_mode: "Markdown",
          disable_web_page_preview: true,
        }),
      }
    );

    const result = (await response.json()) as { ok: boolean; result?: { message_id: number }; description?: string };

    if (result.ok) {
      console.log(`  ✓ Telegram sent (message_id: ${result.result?.message_id})`);
    } else {
      console.error(`  ✗ Telegram error: ${result.description}`);
    }
  } catch (err) {
    console.error("  ✗ Telegram send failed:", (err as Error).message);
  }
}
