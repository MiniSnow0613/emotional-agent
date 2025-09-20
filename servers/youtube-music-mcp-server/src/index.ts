// index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError
} from '@modelcontextprotocol/sdk/types.js';
import axios from 'axios';
import { exec, spawn } from 'child_process';
import os from 'os';
import { promisify } from 'util';

const execAsync = promisify(exec);

// ====== ENV CHECK ======
const API_KEY = process.env.YOUTUBE_API_KEY;
if (!API_KEY) {
  throw new Error('YOUTUBE_API_KEY environment variable is required');
}

// ====== INPUT TYPES ======
interface PlaySongArgs {
  song_name?: string;
  artist_name?: string;
}

const isValidPlaySongArgs = (args: unknown): args is PlaySongArgs => {
  const obj = args as Record<string, unknown>;
  return (
    typeof args === 'object' &&
    args !== null &&
    (obj['song_name'] === undefined || typeof obj['song_name'] === 'string') &&
    (obj['artist_name'] === undefined || typeof obj['artist_name'] === 'string')
  );
};

interface SearchResult {
  title: string;
  videoId: string;
  description: string;
}

class YoutubeMusicServer {
  private server: Server;
  preferences: Record<string, unknown>;
  log: string[];
  private youtubeApi: ReturnType<typeof axios.create>;

  constructor() {
    this.server = new Server(
      {
        name: 'youtube-music-server',
        version: '1.0.0',
      },
      {
        capabilities: {
          resources: {},
          tools: {},
        },
      }
    );
    this.preferences = {};
    this.log = [];

    this.youtubeApi = axios.create({
      baseURL: 'https://www.googleapis.com/youtube/v3',
      params: {
        key: API_KEY,
        part: 'snippet',
        maxResults: 5,
        type: 'video',
      },
    });

    this.setupToolHandlers();

    this.server.onerror = (error) => console.error('[MCP Error]', error);
    process.on('SIGINT', async () => {
      await this.server.close();
      process.exit(0);
    });
  }

  // ====== BROWSER OPEN HELPERS (Windows Chrome only) ======
  private async openUrlInBrowser(url: string): Promise<boolean> {
    const platform = os.platform();
    console.error(`Platform: ${platform}; URL: ${url}`);

    if (platform !== 'win32') {
      console.error('This server is configured for Windows only.');
      return false;
    }

    try {
      await this.openUrlWindows(url);
      return true;
    } catch (error) {
      console.error(`Failed to open URL: ${error instanceof Error ? error.message : String(error)}`);
      return false;
    }
  }

  private async openUrlWindows(url: string): Promise<void> {
    const chromePaths = [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
      'chrome' // if in PATH
    ];

    // 嘗試依序打開 Chrome
    for (const p of chromePaths) {
      try {
        await execAsync(`"${p}" "${url}"`);
        return;
      } catch {
        continue;
      }
    }

    // 備援方法（用系統預設瀏覽器開，但通常還是 Chrome）
    const fallbacks: Array<() => Promise<void>> = [
      async () => { await execAsync(`start "" "${url}"`); },
      async () => { await execAsync(`rundll32 url.dll,FileProtocolHandler "${url}"`); },
      async () =>
        new Promise<void>((resolve, reject) => {
          const child = spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' });
          child.unref();
          child.on('error', reject);
          setTimeout(() => resolve(), 800);
        })
    ];

    let lastError: Error | null = null;
    for (const f of fallbacks) {
      try { await f(); return; } catch (e) { lastError = e as Error; }
    }
    throw lastError ?? new Error('Failed to open URL with Chrome');
  }

  // ====== TOOL HANDLERS ======
  private setupToolHandlers() {
    this.server.setRequestHandler(ListToolsRequestSchema, async () => ({
      tools: [
        {
          name: 'play_song',
          description: 'Play a song on YouTube Music',
          inputSchema: {
            type: 'object',
            properties: {
              song_name: { type: 'string', description: 'Name of the song to play' },
              artist_name: { type: 'string', description: 'Name of the artist' }
            },
            required: ['song_name']
          }
        }
      ]
    }));

    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name !== 'play_song') {
        throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${request.params.name}`);
      }

      if (!isValidPlaySongArgs(request.params.arguments)) {
        throw new McpError(ErrorCode.InvalidParams, 'Invalid play_song arguments');
      }

      const { song_name, artist_name } = request.params.arguments;
      const searchQuery = artist_name ? `${song_name} ${artist_name}` : String(song_name);

      console.error(`Searching for song: ${searchQuery}`);

      try {
        const response = await this.youtubeApi.get('/search', { params: { q: searchQuery } });
        const searchResults: SearchResult[] = (response.data.items ?? []).map((item: any) => ({
          title: item.snippet?.title,
          videoId: item.id?.videoId,
          description: item.snippet?.description
        }));

        if (searchResults.length === 0) {
          return { content: [{ type: 'text', text: `No search results found for: ${searchQuery}` }] };
        }

        const top = searchResults[0];
        const urls = [
          `https://music.youtube.com/watch?v=${top.videoId}`,
          `https://www.youtube.com/watch?v=${top.videoId}`
        ];

        let opened = false;
        for (const url of urls) {
          const ok = await this.openUrlInBrowser(url);
          if (ok) { opened = true; break; }
        }

        if (opened) {
          return { content: [{ type: 'text', text: `Playing top result: ${top.title}` }] };
        } else {
          return {
            content: [{
              type: 'text',
              text:
                `Found: ${top.title}\n` +
                `無法自動開啟 Chrome。請手動點擊：\n` +
                `🎵 YouTube Music: ${urls[0]}\n` +
                `🎬 YouTube: ${urls[1]}`
            }]
          };
        }
      } catch (error: unknown) {
        const msg = error instanceof Error ? error.message : String(error);
        throw new McpError(ErrorCode.InternalError, `Error searching for song: ${msg}`);
      }
    });
  }

  async run() {
    const transport = new StdioServerTransport();
    await this.server.connect(transport);
    console.error('Youtube Music MCP server running on stdio (Windows + Chrome only)');
  }
}

const server = new YoutubeMusicServer();
server.run().catch(console.error);

