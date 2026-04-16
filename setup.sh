#!/bin/bash
set -e

echo "🚀 Building Search + Extract API..."

cat > src/types/index.ts << 'HEREDOC'
export type SearchIntent = 'summary' | 'facts' | 'news' | 'research' | 'extract';

export interface SearchRequest {
  query: string;
  intent?: SearchIntent;
  max_results?: number;
  extract_fields?: string[];
}

export interface SearchSource {
  title: string;
  url: string;
  snippet: string;
  relevance: number;
}

export interface SearchResponse {
  id: string;
  query: string;
  intent: SearchIntent;
  answer: string;
  sources: SearchSource[];
  structured_data: Record<string, unknown>;
  latency_ms: number;
  created_at: string;
}

export interface BatchRequest {
  searches: SearchRequest[];
}
HEREDOC

cat > src/utils/config.ts << 'HEREDOC'
import 'dotenv/config';
function required(key: string): string { const val = process.env[key]; if (!val) throw new Error(`Missing required env var: ${key}`); return val; }
function optional(key: string, fallback: string): string { return process.env[key] ?? fallback; }
export const config = {
  anthropic: { apiKey: required('ANTHROPIC_API_KEY'), model: optional('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514') },
  server: { port: parseInt(optional('PORT', '3000'), 10), nodeEnv: optional('NODE_ENV', 'development'), apiVersion: optional('API_VERSION', 'v1') },
  rateLimit: { windowMs: parseInt(optional('RATE_LIMIT_WINDOW_MS', '60000'), 10), maxFree: parseInt(optional('RATE_LIMIT_MAX_FREE', '5'), 10), maxPro: parseInt(optional('RATE_LIMIT_MAX_PRO', '200'), 10) },
  logging: { level: optional('LOG_LEVEL', 'info') },
} as const;
HEREDOC

cat > src/utils/logger.ts << 'HEREDOC'
export const logger = {
  info: (obj: unknown, msg?: string) => console.log(JSON.stringify({ level: 'info', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  warn: (obj: unknown, msg?: string) => console.warn(JSON.stringify({ level: 'warn', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  error: (obj: unknown, msg?: string) => console.error(JSON.stringify({ level: 'error', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
};
HEREDOC

cat > src/utils/validation.ts << 'HEREDOC'
import Joi from 'joi';
export const searchSchema = Joi.object({
  query: Joi.string().min(1).max(500).required().messages({ 'any.required': 'query is required', 'string.max': 'query must be under 500 characters' }),
  intent: Joi.string().valid('summary', 'facts', 'news', 'research', 'extract').default('summary'),
  max_results: Joi.number().integer().min(1).max(10).default(5),
  extract_fields: Joi.array().items(Joi.string()).max(10).optional(),
});
export const batchSchema = Joi.object({
  searches: Joi.array().items(searchSchema).min(1).max(5).required().messages({ 'array.max': 'Batch accepts a maximum of 5 searches per request' }),
});
HEREDOC

cat > src/utils/scraper.ts << 'HEREDOC'
import axios from 'axios';
import * as cheerio from 'cheerio';
import { logger } from './logger';

export async function fetchPage(url: string): Promise<string> {
  try {
    const response = await axios.get(url, {
      timeout: 8000,
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; SearchExtractBot/1.0)' },
      maxRedirects: 3,
    });
    const $ = cheerio.load(response.data as string);
    $('script, style, nav, footer, header, iframe, noscript').remove();
    const title = $('title').text().trim();
    const metaDesc = $('meta[name="description"]').attr('content') ?? '';
    const h1 = $('h1').first().text().trim();
    const bodyText = $('body').text().replace(/\s+/g, ' ').trim().slice(0, 3000);
    return `Title: ${title}\nDescription: ${metaDesc}\nH1: ${h1}\nContent: ${bodyText}`;
  } catch (err) {
    logger.warn({ url, err }, 'Failed to fetch page');
    return '';
  }
}

export async function searchDuckDuckGo(query: string, maxResults: number): Promise<{ title: string; url: string; snippet: string }[]> {
  try {
    const encoded = encodeURIComponent(query);
    const response = await axios.get(`https://html.duckduckgo.com/html/?q=${encoded}`, {
      timeout: 10000,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': 'text/html',
      },
    });
    const $ = cheerio.load(response.data as string);
    const results: { title: string; url: string; snippet: string }[] = [];

    $('.result').each((i, el) => {
      if (i >= maxResults) return false;
      const title = $(el).find('.result__title').text().trim();
      const url = $(el).find('.result__url').text().trim();
      const snippet = $(el).find('.result__snippet').text().trim();
      if (title && url) {
        results.push({
          title,
          url: url.startsWith('http') ? url : `https://${url}`,
          snippet,
        });
      }
    });

    return results;
  } catch (err) {
    logger.warn({ query, err }, 'DuckDuckGo search failed');
    return [];
  }
}
HEREDOC

cat > src/services/search.service.ts << 'HEREDOC'
import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuidv4 } from 'uuid';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import { searchDuckDuckGo, fetchPage } from '../utils/scraper';
import type { SearchRequest, SearchResponse, SearchIntent, SearchSource } from '../types/index';

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const INTENT_PROMPTS: Record<SearchIntent, string> = {
  summary: 'Provide a concise summary of the key information found.',
  facts: 'Extract the most important facts and data points.',
  news: 'Summarize the latest news and developments on this topic.',
  research: 'Provide a comprehensive research summary with key findings.',
  extract: 'Extract and structure the specific data requested.',
};

export async function searchAndExtract(req: SearchRequest): Promise<SearchResponse> {
  const id = `search_${uuidv4().replace(/-/g, '').slice(0, 12)}`;
  const t0 = Date.now();
  const intent = req.intent ?? 'summary';
  const maxResults = req.max_results ?? 5;

  logger.info({ id, query: req.query, intent }, 'Starting search');

  // Search DuckDuckGo
  const rawResults = await searchDuckDuckGo(req.query, maxResults);

  // Fetch top 3 pages for content
  const pageContents = await Promise.allSettled(
    rawResults.slice(0, 3).map(r => fetchPage(r.url))
  );

  const pageTexts = pageContents
    .map((r, i) => r.status === 'fulfilled' && r.value ? `Source ${i + 1} (${rawResults[i]?.url}):\n${r.value}` : '')
    .filter(Boolean)
    .join('\n\n---\n\n');

  // Build sources with relevance
  const sources: SearchSource[] = rawResults.map((r, i) => ({
    title: r.title,
    url: r.url,
    snippet: r.snippet,
    relevance: Math.max(0.5, 1 - i * 0.1),
  }));

  // Use Claude to extract and structure
  const extractFields = req.extract_fields?.length ? `\nExtract these specific fields: ${req.extract_fields.join(', ')}` : '';

  const prompt = `You are a web research assistant. A user searched for: "${req.query}"

Intent: ${INTENT_PROMPTS[intent]}${extractFields}

Here is content from the top search results:
${pageTexts || rawResults.map(r => `${r.title}: ${r.snippet}`).join('\n')}

Return ONLY valid JSON:
{
  "answer": "<comprehensive answer based on the search results>",
  "structured_data": {
    <extract relevant structured data as key-value pairs based on the query and intent>
  }
}

Rules:
- answer should be 2-5 sentences, directly addressing the query
- structured_data should contain the most useful extracted data (lists, numbers, names, dates etc.)
- Be factual and cite information from the sources only
- If no good results found, say so honestly`;

  let answer = 'No relevant results found for this query.';
  let structuredData: Record<string, unknown> = {};

  try {
    const response = await client.messages.create({
      model: config.anthropic.model,
      max_tokens: 1024,
      messages: [{ role: 'user', content: prompt }],
    });

    const raw = response.content.find(b => b.type === 'text')?.text ?? '{}';
    const parsed = JSON.parse(raw.replace(/```json|```/g, '').trim());
    answer = parsed.answer ?? answer;
    structuredData = parsed.structured_data ?? {};
  } catch (err) {
    logger.warn({ id, err }, 'Claude extraction failed — using snippets');
    answer = rawResults.slice(0, 3).map(r => r.snippet).filter(Boolean).join(' ') || answer;
  }

  logger.info({ id, resultCount: sources.length }, 'Search complete');

  return {
    id, query: req.query, intent, answer, sources, structured_data: structuredData,
    latency_ms: Date.now() - t0, created_at: new Date().toISOString(),
  };
}
HEREDOC

cat > src/middleware/error.middleware.ts << 'HEREDOC'
import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
export function errorHandler(err: Error, req: Request, res: Response, _next: NextFunction): void {
  logger.error({ err, path: req.path }, 'Unhandled error');
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' } });
}
export function notFound(req: Request, res: Response): void { res.status(404).json({ error: { code: 'NOT_FOUND', message: `Route ${req.method} ${req.path} not found` } }); }
HEREDOC

cat > src/middleware/ratelimit.middleware.ts << 'HEREDOC'
import rateLimit from 'express-rate-limit';
import { config } from '../utils/config';
export const rateLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs, max: config.rateLimit.maxFree,
  standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => req.headers['authorization']?.replace('Bearer ', '') ?? req.ip ?? 'unknown',
  handler: (_req, res) => { res.status(429).json({ error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests.' } }); },
});
HEREDOC

cat > src/routes/health.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
export const healthRouter = Router();
const startTime = Date.now();
healthRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok', version: '1.0.0', uptime_seconds: Math.floor((Date.now() - startTime) / 1000), timestamp: new Date().toISOString() });
});
HEREDOC

cat > src/routes/search.route.ts << 'HEREDOC'
import { Router, Request, Response, NextFunction } from 'express';
import { searchSchema, batchSchema } from '../utils/validation';
import { searchAndExtract } from '../services/search.service';
import type { SearchRequest, BatchRequest } from '../types/index';
export const searchRouter = Router();

searchRouter.post('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = searchSchema.validate(req.body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map(d => d.message) } }); return; }
    res.status(200).json(await searchAndExtract(value as SearchRequest));
  } catch (err) { next(err); }
});

searchRouter.get('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = searchSchema.validate({ query: req.query.query, intent: req.query.intent, max_results: req.query.max_results ? parseInt(req.query.max_results as string, 10) : undefined }, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map(d => d.message) } }); return; }
    res.status(200).json(await searchAndExtract(value as SearchRequest));
  } catch (err) { next(err); }
});

searchRouter.post('/batch', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = batchSchema.validate(req.body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map(d => d.message) } }); return; }
    const t0 = Date.now();
    const results = await Promise.allSettled((value as BatchRequest).searches.map((s: SearchRequest) => searchAndExtract(s)));
    const out = results.map(r => r.status === 'fulfilled' ? r.value : { error: r.reason instanceof Error ? r.reason.message : 'Unknown' });
    res.status(200).json({ batch_id: `batch_${Date.now()}`, total: (value as BatchRequest).searches.length, results: out, latency_ms: Date.now() - t0 });
  } catch (err) { next(err); }
});
HEREDOC

cat > src/routes/openapi.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
import { config } from '../utils/config';
export const openapiRouter = Router();
export const docsRouter = Router();

const docsHtml = `<!DOCTYPE html>
<html>
<head>
  <title>Search + Extract API — Docs</title>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 2rem; color: #333; }
    h1 { font-size: 1.8rem; margin-bottom: 0.25rem; }
    h2 { font-size: 1.2rem; margin-top: 2rem; border-bottom: 1px solid #eee; padding-bottom: 0.5rem; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; margin-right: 8px; }
    .get { background: #e3f2fd; color: #1565c0; }
    .post { background: #e8f5e9; color: #2e7d32; }
    .endpoint { background: #f5f5f5; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; }
    .path { font-family: monospace; font-size: 1rem; font-weight: bold; }
    .desc { color: #666; font-size: 0.9rem; margin-top: 0.25rem; }
    pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; font-size: 13px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 8px; }
    th, td { text-align: left; padding: 8px; border: 1px solid #ddd; }
    th { background: #f5f5f5; }
  </style>
</head>
<body>
  <h1>Search + Extract API</h1>
  <p>Agent-ready web search — search the web and get clean, structured answers in one call.</p>
  <p><strong>Base URL:</strong> <code>https://search-extract-api.onrender.com</code></p>

  <h2>Quick start</h2>
  <pre>const res = await fetch("https://search-extract-api.onrender.com/v1/search", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    query: "best AI startups 2026",
    intent: "research"
  })
});
const { answer, sources, structured_data } = await res.json();</pre>

  <h2>Intent modes</h2>
  <table>
    <tr><th>Intent</th><th>Best for</th></tr>
    <tr><td>summary</td><td>Quick overview of any topic</td></tr>
    <tr><td>facts</td><td>Extract specific facts and data points</td></tr>
    <tr><td>news</td><td>Latest news and developments</td></tr>
    <tr><td>research</td><td>Comprehensive research with key findings</td></tr>
    <tr><td>extract</td><td>Extract specific fields from results</td></tr>
  </table>

  <h2>Endpoints</h2>
  <div class="endpoint">
    <div><span class="badge post">POST</span><span class="path">/v1/search</span></div>
    <div class="desc">Search and extract structured data</div>
    <pre>curl -X POST https://search-extract-api.onrender.com/v1/search \\
  -H "Content-Type: application/json" \\
  -d '{"query": "latest AI news", "intent": "news"}'</pre>
  </div>
  <div class="endpoint">
    <div><span class="badge get">GET</span><span class="path">/v1/search</span></div>
    <div class="desc">Search via query parameter</div>
    <pre>curl "https://search-extract-api.onrender.com/v1/search?query=OpenAI+news&intent=news"</pre>
  </div>
  <div class="endpoint">
    <div><span class="badge post">POST</span><span class="path">/v1/search/batch</span></div>
    <div class="desc">Run up to 5 searches in one request</div>
    <pre>curl -X POST https://search-extract-api.onrender.com/v1/search/batch \\
  -H "Content-Type: application/json" \\
  -d '{"searches": [{"query": "AI news"}, {"query": "crypto trends"}]}'</pre>
  </div>

  <h2>Example response</h2>
  <pre>{
  "id": "search_abc123",
  "query": "best AI startups 2026",
  "intent": "research",
  "answer": "Top AI startups in 2026 include...",
  "sources": [
    { "title": "Top AI Companies", "url": "https://...", "snippet": "...", "relevance": 0.95 }
  ],
  "structured_data": {
    "companies": ["OpenAI", "Anthropic", "Mistral"],
    "trends": ["agents", "multimodal", "reasoning"]
  },
  "latency_ms": 3240
}</pre>

  <h2>OpenAPI Spec</h2>
  <p><a href="/openapi.json">Download openapi.json</a></p>
</body>
</html>`;

docsRouter.get('/', (_req: Request, res: Response) => { res.setHeader('Content-Type', 'text/html'); res.send(docsHtml); });

openapiRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({
    openapi: '3.0.3',
    info: { title: 'Search + Extract API', version: '1.0.0', description: 'Agent-ready web search — search the web and get clean, structured answers.' },
    servers: [{ url: 'https://search-extract-api.onrender.com', description: 'Production' }, { url: `http://localhost:${config.server.port}`, description: 'Local' }],
    paths: {
      '/v1/health': { get: { summary: 'Health check', operationId: 'getHealth', responses: { '200': { description: 'OK' } } } },
      '/v1/search': {
        post: { summary: 'Search and extract', operationId: 'searchPost', requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/SearchRequest' }, examples: { summary: { summary: 'Summary', value: { query: 'latest AI news', intent: 'summary' } }, research: { summary: 'Research', value: { query: 'best AI startups 2026', intent: 'research', max_results: 5 } }, extract: { summary: 'Extract fields', value: { query: 'OpenAI GPT-5 specs', intent: 'extract', extract_fields: ['model_name', 'parameters', 'release_date'] } } } } } }, responses: { '200': { description: 'Search results' }, '422': { description: 'Validation error' } } },
        get: { summary: 'Search via GET', operationId: 'searchGet', parameters: [{ name: 'query', in: 'query', required: true, schema: { type: 'string' } }, { name: 'intent', in: 'query', schema: { type: 'string' } }], responses: { '200': { description: 'Search results' } } },
      },
      '/v1/search/batch': { post: { summary: 'Run up to 5 searches', operationId: 'searchBatch', requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/BatchRequest' } } } }, responses: { '200': { description: 'Batch results' } } } },
    },
    components: {
      schemas: {
        SearchRequest: { type: 'object', required: ['query'], properties: { query: { type: 'string', maxLength: 500 }, intent: { type: 'string', enum: ['summary', 'facts', 'news', 'research', 'extract'], default: 'summary' }, max_results: { type: 'integer', minimum: 1, maximum: 10, default: 5 }, extract_fields: { type: 'array', items: { type: 'string' } } } },
        BatchRequest: { type: 'object', required: ['searches'], properties: { searches: { type: 'array', items: { $ref: '#/components/schemas/SearchRequest' }, minItems: 1, maxItems: 5 } } },
      },
    },
  });
});
HEREDOC

cat > src/app.ts << 'HEREDOC'
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { searchRouter } from './routes/search.route';
import { healthRouter } from './routes/health.route';
import { openapiRouter, docsRouter } from './routes/openapi.route';
import { errorHandler, notFound } from './middleware/error.middleware';
import { rateLimiter } from './middleware/ratelimit.middleware';
import { config } from './utils/config';
const app = express();
app.use(helmet()); app.use(cors()); app.use(compression());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));
app.use(`/${config.server.apiVersion}/search`, rateLimiter);
app.use(`/${config.server.apiVersion}/search`, searchRouter);
app.use(`/${config.server.apiVersion}/health`, healthRouter);
app.use('/openapi.json', openapiRouter);
app.use('/docs', docsRouter);
app.get('/', (_req, res) => res.redirect(`/${config.server.apiVersion}/health`));
app.use(notFound);
app.use(errorHandler);
export { app };
HEREDOC

cat > src/index.ts << 'HEREDOC'
import { app } from './app';
import { config } from './utils/config';

const server = app.listen(config.server.port, () => {
  console.log(`🚀 Search + Extract API started on port ${config.server.port}`);
});

const shutdown = (signal: string) => {
  console.log(`Shutting down (${signal})`);
  server.close(() => { console.log('Closed'); process.exit(0); });
  setTimeout(() => process.exit(1), 10_000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => console.error('Unhandled rejection:', reason));
process.on('uncaughtException', (err) => { console.error('Uncaught exception:', err); process.exit(1); });
HEREDOC

cat > jest.config.js << 'HEREDOC'
module.exports = { preset: 'ts-jest', testEnvironment: 'node', rootDir: '.', testMatch: ['**/tests/**/*.test.ts'], collectCoverageFrom: ['src/**/*.ts', '!src/index.ts'], setupFiles: ['<rootDir>/tests/setup.ts'] };
HEREDOC

cat > tests/setup.ts << 'HEREDOC'
process.env.ANTHROPIC_API_KEY = 'sk-ant-test-key';
process.env.NODE_ENV = 'test';
process.env.LOG_LEVEL = 'silent';
HEREDOC

cat > .gitignore << 'HEREDOC'
node_modules/
dist/
.env
coverage/
*.log
.DS_Store
HEREDOC

cat > render.yaml << 'HEREDOC'
services:
  - type: web
    name: search-extract-api
    runtime: node
    buildCommand: npm install && npm run build
    startCommand: node dist/index.js
    healthCheckPath: /v1/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: LOG_LEVEL
        value: info
      - key: ANTHROPIC_API_KEY
        sync: false
HEREDOC

echo ""
echo "✅ All files created! Run: npm install"