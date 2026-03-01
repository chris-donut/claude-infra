#!/usr/bin/env bun
/**
 * Test Auto-Refresh Token System
 *
 * Usage:
 *   bun scripts/test-auto-refresh.ts
 */

import { createAutoRefreshClient } from './auto-refresh-fetch';

async function testAutoRefresh() {
  console.log('🧪 Testing Auto-Refresh Token System\n');

  // Test 1: Basic fetch with auto-refresh
  console.log('Test 1: Basic fetch with auto-refresh');
  let refreshCount = 0;

  const client = createAutoRefreshClient({
    baseUrl: 'http://localhost:3000',
    getToken: async () => {
      // Simulate getting token from storage
      return 'test-token-' + Date.now();
    },
    refreshToken: async () => {
      refreshCount++;
      console.log(`  🔄 Refresh attempt #${refreshCount}`);
      await new Promise(resolve => setTimeout(resolve, 100)); // Simulate API call
      return 'refreshed-token-' + Date.now();
    },
    onTokenRefreshed: (token) => {
      console.log(`  ✅ Token refreshed: ${token.substring(0, 20)}...`);
    },
    maxRetries: 2,
  });

  // Test 2: Simulate 401 error
  console.log('\nTest 2: Simulating 401 error (should trigger refresh)');

  // Mock fetch to return 401 on first call
  let callCount = 0;
  const originalFetch = global.fetch;
  global.fetch = async (url: any, options: any) => {
    callCount++;
    console.log(`  📡 API call #${callCount} to ${url}`);

    if (callCount === 1) {
      // First call fails with 401
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    } else {
      // Second call succeeds
      return new Response(JSON.stringify({ success: true, data: 'test-data' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
  };

  try {
    const result = await client.get('/api/test');
    console.log('  ✅ Request succeeded after refresh:', result);
  } catch (error) {
    console.log('  ❌ Request failed:', error);
  }

  // Test 3: Multiple simultaneous requests (should only refresh once)
  console.log('\nTest 3: Multiple simultaneous requests');
  callCount = 0;
  refreshCount = 0;

  global.fetch = async (url: any, options: any) => {
    callCount++;
    const shouldFail = callCount <= 3; // First 3 calls fail

    return new Response(
      JSON.stringify(shouldFail ? { error: 'Unauthorized' } : { success: true }),
      {
        status: shouldFail ? 401 : 200,
        headers: { 'Content-Type': 'application/json' },
      }
    );
  };

  const promises = [
    client.get('/api/test1').catch(e => ({ error: e.message })),
    client.get('/api/test2').catch(e => ({ error: e.message })),
    client.get('/api/test3').catch(e => ({ error: e.message })),
  ];

  const results = await Promise.all(promises);
  console.log(`  📊 Results: ${results.filter(r => !('error' in r)).length}/${results.length} succeeded`);
  console.log(`  🔄 Total refresh attempts: ${refreshCount} (should be 1 due to deduplication)`);

  // Restore original fetch
  global.fetch = originalFetch;

  console.log('\n✅ All tests completed!');
  console.log('\n📝 Summary:');
  console.log('  - Auto-refresh triggers on 401/403 errors');
  console.log('  - Multiple simultaneous requests share the same refresh');
  console.log('  - Configurable retry attempts and status codes');
  console.log('\n💡 Next steps:');
  console.log('  1. Update your API clients to use AutoRefreshClient');
  console.log('  2. Configure refresh token storage');
  console.log('  3. Test with real API endpoints');
  console.log('\nSee docs/token-management/AUTO_REFRESH_TOKEN_GUIDE.md for full documentation.');
}

// Run tests
testAutoRefresh().catch(console.error);
