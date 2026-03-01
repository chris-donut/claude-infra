#!/usr/bin/env bun
/**
 * Interactive Token Setup
 * Guides you through setting up all required tokens for Donut development
 *
 * Usage:
 *   bun scripts/setup-tokens.ts
 *   bun scripts/setup-tokens.ts --verify-only
 *   bun scripts/setup-tokens.ts --reset
 */

import fs from 'fs';
import path from 'path';
import { createInterface } from 'readline';

const ENV_FILE = path.join(process.cwd(), '.env.local');
const TOKEN_STORAGE = '/tmp/donut-tokens';

interface TokenConfig {
  name: string;
  envVar: string;
  description: string;
  required: boolean;
  example: string;
  testUrl?: string;
  validator?: (token: string) => boolean;
}

const TOKENS: TokenConfig[] = [
  {
    name: 'Claude API',
    envVar: 'ANTHROPIC_API_KEY',
    description: 'Claude API key for AI features',
    required: true,
    example: 'sk-ant-api03-...',
    testUrl: 'https://api.anthropic.com/v1/messages',
    validator: (token) => token.startsWith('sk-ant-'),
  },
  {
    name: 'Marketplace API',
    envVar: 'MARKETPLACE_API_KEY',
    description: 'API key for Skills Marketplace',
    required: false,
    example: 'bot-...',
  },
  {
    name: 'Google OAuth Client ID',
    envVar: 'GOOGLE_CLIENT_ID',
    description: 'Google OAuth client ID for NextAuth',
    required: false,
    example: '123456789-abc.apps.googleusercontent.com',
  },
  {
    name: 'Google OAuth Client Secret',
    envVar: 'GOOGLE_CLIENT_SECRET',
    description: 'Google OAuth client secret',
    required: false,
    example: 'GOCSPX-...',
  },
  {
    name: 'NextAuth Secret',
    envVar: 'NEXTAUTH_SECRET',
    description: 'Secret for NextAuth session encryption (run: openssl rand -base64 32)',
    required: true,
    example: 'Run: openssl rand -base64 32',
    validator: (token) => token.length >= 32,
  },
  {
    name: 'NextAuth URL',
    envVar: 'NEXTAUTH_URL',
    description: 'Base URL for NextAuth callbacks',
    required: true,
    example: 'http://localhost:3000',
  },
];

class TokenSetup {
  private rl = createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  private currentEnv: Record<string, string> = {};

  async setup() {
    console.log('🔑 Donut Token Setup\n');
    console.log('This will guide you through setting up authentication tokens.\n');

    // Load existing .env file
    this.loadExistingEnv();

    // Check current status
    await this.showStatus();

    const shouldConfigure = await this.ask('\nWould you like to configure tokens now? (y/n): ');
    if (shouldConfigure.toLowerCase() !== 'y') {
      console.log('\n✅ Setup cancelled. Run again when ready.');
      this.rl.close();
      return;
    }

    console.log('\n📝 Token Configuration\n');

    // Configure each token
    for (const token of TOKENS) {
      await this.configureToken(token);
    }

    // Save to .env.local
    await this.saveEnvFile();

    // Create token storage directory
    this.createTokenStorage();

    // Show next steps
    this.showNextSteps();

    this.rl.close();
  }

  async verify() {
    console.log('🔍 Verifying Token Configuration\n');

    this.loadExistingEnv();

    let allValid = true;

    for (const token of TOKENS) {
      const value = this.currentEnv[token.envVar];
      const exists = !!value;
      const valid = exists && (!token.validator || token.validator(value));

      const status = valid ? '✅' : token.required ? '❌' : '⚠️';
      const label = valid ? 'Valid' : !exists ? 'Missing' : 'Invalid';

      console.log(`${status} ${token.name}`);
      console.log(`   ${token.envVar}: ${label}`);

      if (exists && value.length > 20) {
        console.log(`   Value: ${value.substring(0, 8)}...${value.substring(value.length - 4)}`);
      }

      if (token.required && !valid) {
        allValid = false;
      }

      console.log();
    }

    if (allValid) {
      console.log('✅ All required tokens are configured!\n');

      // Test Claude API
      await this.testClaudeAPI();
    } else {
      console.log('❌ Some required tokens are missing or invalid.\n');
      console.log('Run: bun scripts/setup-tokens.ts\n');
    }

    return allValid;
  }

  async reset() {
    console.log('⚠️  Reset Token Configuration\n');

    const confirm = await this.ask('This will remove all tokens from .env.local. Continue? (y/n): ');
    if (confirm.toLowerCase() !== 'y') {
      console.log('✅ Reset cancelled.');
      this.rl.close();
      return;
    }

    if (fs.existsSync(ENV_FILE)) {
      fs.unlinkSync(ENV_FILE);
      console.log(`✅ Removed ${ENV_FILE}`);
    }

    if (fs.existsSync(TOKEN_STORAGE)) {
      fs.rmSync(TOKEN_STORAGE, { recursive: true });
      console.log(`✅ Removed ${TOKEN_STORAGE}`);
    }

    console.log('\n✅ Token configuration reset complete.');
    console.log('Run setup again: bun scripts/setup-tokens.ts\n');

    this.rl.close();
  }

  private loadExistingEnv() {
    if (fs.existsSync(ENV_FILE)) {
      const content = fs.readFileSync(ENV_FILE, 'utf-8');
      const lines = content.split('\n');

      for (const line of lines) {
        const match = line.match(/^([^=]+)=(.*)$/);
        if (match) {
          const [, key, value] = match;
          this.currentEnv[key.trim()] = value.trim().replace(/^["']|["']$/g, '');
        }
      }
    }

    // Also check environment variables
    for (const token of TOKENS) {
      if (process.env[token.envVar] && !this.currentEnv[token.envVar]) {
        this.currentEnv[token.envVar] = process.env[token.envVar]!;
      }
    }
  }

  private async showStatus() {
    console.log('Current Status:\n');

    for (const token of TOKENS) {
      const value = this.currentEnv[token.envVar];
      const status = value ? '✅' : token.required ? '❌' : '⚠️';
      const label = value ? 'Configured' : 'Not configured';

      console.log(`${status} ${token.name}: ${label}`);
    }
  }

  private async configureToken(token: TokenConfig) {
    console.log(`\n${token.name}`);
    console.log(`Description: ${token.description}`);
    console.log(`Environment variable: ${token.envVar}`);

    const current = this.currentEnv[token.envVar];
    if (current) {
      const masked = current.length > 20
        ? `${current.substring(0, 8)}...${current.substring(current.length - 4)}`
        : current;
      console.log(`Current value: ${masked}`);
    }

    if (!token.required) {
      const shouldSet = await this.ask('Set this token? (y/n, default: n): ');
      if (shouldSet.toLowerCase() !== 'y') {
        return;
      }
    }

    const value = await this.ask(`Enter ${token.name} (${token.example}): `);

    if (value.trim()) {
      if (token.validator && !token.validator(value.trim())) {
        console.log(`⚠️  Warning: Token format looks incorrect. Expected: ${token.example}`);
        const proceed = await this.ask('Use this value anyway? (y/n): ');
        if (proceed.toLowerCase() !== 'y') {
          return;
        }
      }

      this.currentEnv[token.envVar] = value.trim();
      console.log('✅ Saved');
    } else if (token.required) {
      console.log('⚠️  This token is required. Using empty value.');
    }
  }

  private async saveEnvFile() {
    console.log('\n💾 Saving configuration...\n');

    let content = '# Donut Token Configuration\n';
    content += `# Generated: ${new Date().toISOString()}\n\n`;

    for (const token of TOKENS) {
      const value = this.currentEnv[token.envVar];
      if (value) {
        content += `# ${token.description}\n`;
        content += `${token.envVar}="${value}"\n\n`;
      }
    }

    fs.writeFileSync(ENV_FILE, content, 'utf-8');
    console.log(`✅ Saved to: ${ENV_FILE}`);

    // Also save individual tokens to storage
    if (!fs.existsSync(TOKEN_STORAGE)) {
      fs.mkdirSync(TOKEN_STORAGE, { recursive: true });
    }

    for (const token of TOKENS) {
      const value = this.currentEnv[token.envVar];
      if (value) {
        const tokenFile = path.join(TOKEN_STORAGE, `${token.envVar}.token`);
        fs.writeFileSync(tokenFile, value, 'utf-8');
        fs.chmodSync(tokenFile, 0o600);
      }
    }

    console.log(`✅ Saved tokens to: ${TOKEN_STORAGE}`);
  }

  private createTokenStorage() {
    if (!fs.existsSync(TOKEN_STORAGE)) {
      fs.mkdirSync(TOKEN_STORAGE, { recursive: true });
    }
  }

  private showNextSteps() {
    console.log('\n✨ Setup Complete!\n');
    console.log('Next Steps:\n');

    console.log('1. Load tokens in your shell:');
    console.log('   source <(bun scripts/export-token.ts all --shell)\n');

    console.log('2. Verify configuration:');
    console.log('   bun scripts/setup-tokens.ts --verify-only\n');

    console.log('3. Test the Skills Marketplace:');
    console.log('   cd donut-skills-marketplace');
    console.log('   npm run dev\n');

    console.log('4. Test token refresh:');
    console.log('   bun scripts/test-auto-refresh.ts\n');

    console.log('📚 Documentation:');
    console.log('   - Token Export: docs/token-management/TOKEN_EXPORT_GUIDE.md');
    console.log('   - Auto-Refresh: docs/token-management/AUTO_REFRESH_TOKEN_GUIDE.md');
    console.log('   - Quick Start: docs/token-management/QUICK_START_AUTO_REFRESH.md\n');
  }

  private async testClaudeAPI() {
    const apiKey = this.currentEnv.ANTHROPIC_API_KEY;
    if (!apiKey) return;

    console.log('🧪 Testing Claude API connection...\n');

    try {
      const response = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify({
          model: 'claude-3-5-sonnet-20241022',
          max_tokens: 10,
          messages: [{ role: 'user', content: 'Hi' }],
        }),
      });

      if (response.ok) {
        console.log('✅ Claude API: Connected successfully!\n');
      } else {
        const error = await response.text();
        console.log(`❌ Claude API: Failed (${response.status})`);
        console.log(`   ${error.substring(0, 100)}...\n`);
      }
    } catch (error) {
      console.log('❌ Claude API: Connection failed');
      console.log(`   ${error}\n`);
    }
  }

  private ask(question: string): Promise<string> {
    return new Promise((resolve) => {
      this.rl.question(question, resolve);
    });
  }
}

// CLI
async function main() {
  const args = process.argv.slice(2);

  const setup = new TokenSetup();

  if (args.includes('--verify-only') || args.includes('-v')) {
    await setup.verify();
  } else if (args.includes('--reset')) {
    await setup.reset();
  } else if (args.includes('--help') || args.includes('-h')) {
    console.log(`
🔑 Donut Token Setup

Usage:
  bun scripts/setup-tokens.ts [options]

Options:
  --verify-only, -v    Verify existing configuration
  --reset              Reset all tokens
  --help, -h           Show this help

Examples:
  bun scripts/setup-tokens.ts              # Interactive setup
  bun scripts/setup-tokens.ts --verify     # Verify tokens
  bun scripts/setup-tokens.ts --reset      # Reset all tokens
`);
  } else {
    await setup.setup();
  }
}

main().catch(console.error);
