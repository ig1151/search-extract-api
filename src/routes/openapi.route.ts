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
