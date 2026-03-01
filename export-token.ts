#!/usr/bin/env bun
/**
 * Token Export Utility
 * Exports authentication tokens for use in scripts and external tools
 *
 * Usage:
 *   bun scripts/export-token.ts [service] [--output-file PATH]
 *
 * Services:
 *   - marketplace: Export Marketplace API token
 *   - claude: Export Claude API token from environment
 *   - nextauth: Export NextAuth session token
 *   - all: Export all available tokens
 *
 * Examples:
 *   bun scripts/export-token.ts marketplace
 *   bun scripts/export-token.ts all --output-file /tmp/tokens.json
 *   bun scripts/export-token.ts claude --output-file ~/.claude-token
 */

import fs from 'fs';
import path from 'path';

interface TokenExport {
  service: string;
  token: string | null;
  expiresAt?: string;
  source: string;
  exportedAt: string;
}

class TokenExporter {
  private tokens: TokenExport[] = [];

  /**
   * Export Claude API token from environment
   */
  exportClaudeToken(): TokenExport {
    const token = process.env.ANTHROPIC_API_KEY || process.env.CLAUDE_API_KEY || null;

    return {
      service: 'claude-api',
      token,
      source: token ? 'environment variable' : 'not found',
      exportedAt: new Date().toISOString(),
    };
  }

  /**
   * Export Marketplace API token
   */
  exportMarketplaceToken(): TokenExport {
    const token = process.env.MARKETPLACE_API_KEY || process.env.BOT_API_KEYS?.split(',')[0] || null;

    return {
      service: 'marketplace',
      token,
      source: token ? 'environment variable' : 'not found',
      exportedAt: new Date().toISOString(),
    };
  }

  /**
   * Export Google OAuth credentials
   */
  exportGoogleOAuth(): TokenExport {
    const clientId = process.env.GOOGLE_CLIENT_ID;
    const clientSecret = process.env.GOOGLE_CLIENT_SECRET;

    return {
      service: 'google-oauth',
      token: clientId && clientSecret ? JSON.stringify({ clientId, clientSecret }) : null,
      source: 'environment variable',
      exportedAt: new Date().toISOString(),
    };
  }

  /**
   * Export NextAuth secret
   */
  exportNextAuthSecret(): TokenExport {
    const secret = process.env.NEXTAUTH_SECRET || null;

    return {
      service: 'nextauth',
      token: secret,
      source: secret ? 'environment variable' : 'not found',
      exportedAt: new Date().toISOString(),
    };
  }

  /**
   * Read NextAuth session token from browser cookies
   */
  exportNextAuthSession(): TokenExport {
    // This would need to be extracted from browser cookies
    // For now, provide instructions
    return {
      service: 'nextauth-session',
      token: null,
      source: 'Extract from browser: document.cookie.match(/next-auth.session-token=([^;]+)/)[1]',
      exportedAt: new Date().toISOString(),
    };
  }

  /**
   * Export all available tokens
   */
  exportAll(): TokenExport[] {
    return [
      this.exportClaudeToken(),
      this.exportMarketplaceToken(),
      this.exportGoogleOAuth(),
      this.exportNextAuthSecret(),
      this.exportNextAuthSession(),
    ];
  }

  /**
   * Format tokens for display
   */
  formatForDisplay(tokens: TokenExport[]): string {
    let output = '🔑 Token Export\n';
    output += '═'.repeat(60) + '\n\n';

    for (const tokenData of tokens) {
      output += `Service: ${tokenData.service}\n`;
      output += `Status: ${tokenData.token ? '✅ Found' : '❌ Not Found'}\n`;
      output += `Source: ${tokenData.source}\n`;

      if (tokenData.token) {
        const masked = this.maskToken(tokenData.token);
        output += `Token: ${masked}\n`;
      }

      if (tokenData.expiresAt) {
        output += `Expires: ${tokenData.expiresAt}\n`;
      }

      output += `Exported: ${tokenData.exportedAt}\n`;
      output += '─'.repeat(60) + '\n';
    }

    return output;
  }

  /**
   * Mask sensitive token data
   */
  private maskToken(token: string): string {
    if (token.length <= 8) return '***';

    const start = token.substring(0, 4);
    const end = token.substring(token.length - 4);
    const middle = '*'.repeat(Math.min(20, token.length - 8));

    return `${start}${middle}${end}`;
  }

  /**
   * Export tokens to file
   */
  exportToFile(tokens: TokenExport[], filePath: string, format: 'json' | 'env' = 'json'): void {
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    let content: string;

    if (format === 'json') {
      content = JSON.stringify(tokens, null, 2);
    } else {
      // .env format
      content = tokens
        .filter(t => t.token)
        .map(t => {
          const key = t.service.toUpperCase().replace(/-/g, '_') + '_TOKEN';
          return `${key}="${t.token}"`;
        })
        .join('\n');
    }

    fs.writeFileSync(filePath, content, 'utf-8');
    console.log(`✅ Tokens exported to: ${filePath}`);
  }

  /**
   * Create shell export commands
   */
  createShellExports(tokens: TokenExport[]): string {
    let output = '# Export tokens to shell environment\n';
    output += '# Usage: source <(bun scripts/export-token.ts --shell)\n\n';

    for (const tokenData of tokens) {
      if (tokenData.token) {
        const varName = tokenData.service.toUpperCase().replace(/-/g, '_') + '_TOKEN';
        output += `export ${varName}="${tokenData.token}"\n`;
      }
    }

    return output;
  }
}

// CLI Implementation
async function main() {
  const args = process.argv.slice(2);
  const service = args[0] || 'all';
  const outputFileIndex = args.indexOf('--output-file');
  const outputFile = outputFileIndex >= 0 ? args[outputFileIndex + 1] : null;
  const format = args.includes('--env') ? 'env' : 'json';
  const shell = args.includes('--shell');

  const exporter = new TokenExporter();
  let tokens: TokenExport[] = [];

  switch (service) {
    case 'claude':
      tokens = [exporter.exportClaudeToken()];
      break;
    case 'marketplace':
      tokens = [exporter.exportMarketplaceToken()];
      break;
    case 'nextauth':
      tokens = [exporter.exportNextAuthSecret(), exporter.exportNextAuthSession()];
      break;
    case 'google':
      tokens = [exporter.exportGoogleOAuth()];
      break;
    case 'all':
      tokens = exporter.exportAll();
      break;
    default:
      console.error(`❌ Unknown service: ${service}`);
      console.log('\nAvailable services: claude, marketplace, nextauth, google, all');
      process.exit(1);
  }

  if (shell) {
    // Output shell export commands
    console.log(exporter.createShellExports(tokens));
  } else if (outputFile) {
    // Export to file
    exporter.exportToFile(tokens, outputFile, format);
    console.log(exporter.formatForDisplay(tokens));
  } else {
    // Display to console
    console.log(exporter.formatForDisplay(tokens));
  }

  // Show usage instructions
  if (!outputFile && !shell) {
    console.log('\n💡 Usage Instructions:\n');
    console.log('Export to file:');
    console.log('  bun scripts/export-token.ts all --output-file /tmp/tokens.json\n');
    console.log('Export as shell commands:');
    console.log('  source <(bun scripts/export-token.ts all --shell)\n');
    console.log('Export to .env format:');
    console.log('  bun scripts/export-token.ts all --output-file .env.tokens --env\n');
  }
}

main().catch(console.error);
