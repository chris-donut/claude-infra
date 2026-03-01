/**
 * Auto-Refresh Fetch Wrapper
 * Automatically retries API calls with token refresh on 401/403 errors
 *
 * Usage:
 *   import { createAutoRefreshClient } from './utils/auto-refresh-fetch';
 *
 *   const client = createAutoRefreshClient({
 *     baseUrl: 'https://api.example.com',
 *     getToken: () => localStorage.getItem('token'),
 *     refreshToken: async () => {
 *       const response = await fetch('/api/auth/refresh');
 *       const { token } = await response.json();
 *       localStorage.setItem('token', token);
 *       return token;
 *     }
 *   });
 *
 *   // Automatically handles refresh on 401/403
 *   const data = await client.get('/api/skills');
 */

export interface AutoRefreshConfig {
  baseUrl?: string;
  getToken: () => string | null | Promise<string | null>;
  refreshToken: () => Promise<string | null>;
  onTokenRefreshed?: (token: string) => void;
  maxRetries?: number;
  retryStatuses?: number[];
}

export class AutoRefreshClient {
  private config: Required<AutoRefreshConfig>;
  private refreshPromise: Promise<string | null> | null = null;

  constructor(config: AutoRefreshConfig) {
    this.config = {
      baseUrl: config.baseUrl || '',
      getToken: config.getToken,
      refreshToken: config.refreshToken,
      onTokenRefreshed: config.onTokenRefreshed || (() => {}),
      maxRetries: config.maxRetries ?? 1,
      retryStatuses: config.retryStatuses || [401, 403],
    };
  }

  private async getAuthHeaders(): Promise<Record<string, string>> {
    const token = await this.config.getToken();
    if (!token) return {};

    return {
      'Authorization': `Bearer ${token}`,
    };
  }

  private async refreshTokenOnce(): Promise<string | null> {
    // Prevent multiple simultaneous refresh requests
    if (this.refreshPromise) {
      return this.refreshPromise;
    }

    this.refreshPromise = this.config.refreshToken()
      .then(token => {
        if (token) {
          this.config.onTokenRefreshed(token);
        }
        return token;
      })
      .finally(() => {
        this.refreshPromise = null;
      });

    return this.refreshPromise;
  }

  private shouldRetry(status: number, attempt: number): boolean {
    return (
      this.config.retryStatuses.includes(status) &&
      attempt < this.config.maxRetries
    );
  }

  async fetch(
    url: string,
    options: RequestInit = {},
    attempt: number = 0
  ): Promise<Response> {
    const fullUrl = url.startsWith('http') ? url : `${this.config.baseUrl}${url}`;

    const authHeaders = await this.getAuthHeaders();
    const headers = {
      ...authHeaders,
      ...options.headers,
    };

    const response = await fetch(fullUrl, {
      ...options,
      headers,
    });

    // If unauthorized and we can retry, refresh token and try again
    if (this.shouldRetry(response.status, attempt)) {
      const newToken = await this.refreshTokenOnce();

      if (newToken) {
        // Retry with new token
        return this.fetch(url, options, attempt + 1);
      }
    }

    return response;
  }

  async get(url: string, options: RequestInit = {}): Promise<any> {
    const response = await this.fetch(url, { ...options, method: 'GET' });

    if (!response.ok) {
      throw new Error(`GET ${url} failed: ${response.statusText}`);
    }

    return response.json();
  }

  async post(url: string, body?: any, options: RequestInit = {}): Promise<any> {
    const response = await this.fetch(url, {
      ...options,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      throw new Error(`POST ${url} failed: ${response.statusText}`);
    }

    return response.json();
  }

  async put(url: string, body?: any, options: RequestInit = {}): Promise<any> {
    const response = await this.fetch(url, {
      ...options,
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      throw new Error(`PUT ${url} failed: ${response.statusText}`);
    }

    return response.json();
  }

  async delete(url: string, options: RequestInit = {}): Promise<any> {
    const response = await this.fetch(url, { ...options, method: 'DELETE' });

    if (!response.ok) {
      throw new Error(`DELETE ${url} failed: ${response.statusText}`);
    }

    return response.json();
  }
}

export function createAutoRefreshClient(config: AutoRefreshConfig): AutoRefreshClient {
  return new AutoRefreshClient(config);
}
