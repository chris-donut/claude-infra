#!/usr/bin/env node
/**
 * Get NextAuth Session Token from Browser
 *
 * Usage:
 *   1. Open your browser console on the Donut Skills Marketplace
 *   2. Run: copy(await fetch('/api/auth/session').then(r => r.json()))
 *   3. Run this script: node scripts/get-session-token.js
 *
 * Or run this directly in browser console:
 *   copy(document.cookie.match(/next-auth\.session-token=([^;]+)/)?.[1] || 'No session token found')
 */

const fs = require('fs');
const path = require('path');

const SESSION_TOKEN_FILE = path.join(__dirname, '../.session-token');

function getSessionTokenFromCookie() {
  // This needs to be run in the browser console
  const instructions = `
╔════════════════════════════════════════════════════════════════╗
║  How to Extract NextAuth Session Token from Browser           ║
╚════════════════════════════════════════════════════════════════╝

Step 1: Open Donut Skills Marketplace in your browser
        → http://localhost:3000 (or production URL)

Step 2: Open Browser Console (F12 or Cmd+Option+J)

Step 3: Run this command:

        copy(document.cookie.match(/next-auth\\.session-token=([^;]+)/)?.[1] || 'No token found')

Step 4: The token is now in your clipboard!

Step 5: Save it to file:

        echo "YOUR_TOKEN_HERE" > ${SESSION_TOKEN_FILE}

Alternative - Get Full Session:

        fetch('/api/auth/session').then(r => r.json()).then(s => {
          console.log('Session:', s);
          copy(s.accessToken || 'No access token');
        })

Usage in Scripts:

        export NEXTAUTH_TOKEN="\$(cat ${SESSION_TOKEN_FILE})"
        curl -H "Cookie: next-auth.session-token=\$NEXTAUTH_TOKEN" \\
             http://localhost:3000/api/skills/list

`;

  console.log(instructions);
}

function testStoredToken() {
  if (fs.existsSync(SESSION_TOKEN_FILE)) {
    const token = fs.readFileSync(SESSION_TOKEN_FILE, 'utf-8').trim();
    const masked = token.substring(0, 8) + '...' + token.substring(token.length - 8);

    console.log('✅ Stored session token found:');
    console.log(`   ${masked}`);
    console.log(`\nTest the token:\n`);
    console.log(`   curl -H "Cookie: next-auth.session-token=${token}" \\`);
    console.log(`        http://localhost:3000/api/auth/session\n`);
  } else {
    console.log('❌ No stored session token found.');
    console.log(`   Expected location: ${SESSION_TOKEN_FILE}\n`);
  }
}

// Main
console.log('🔑 NextAuth Session Token Extractor\n');
testStoredToken();
getSessionTokenFromCookie();
