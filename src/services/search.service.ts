import { v4 as uuidv4 } from 'uuid';
import { logger } from '../utils/logger';
import { searchDuckDuckGo, fetchPage } from '../utils/scraper';
import type { SearchRequest, SearchResponse, SearchIntent, SearchSource, SearchDecision } from '../types/index';

const OPENROUTER_API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const MODEL = 'anthropic/claude-sonnet-4-5';

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

  const rawResults = await searchDuckDuckGo(req.query, maxResults);

  const pageContents = await Promise.allSettled(
    rawResults.slice(0, 3).map(r => fetchPage(r.url))
  );

  const pageTexts = pageContents
    .map((r, i) => r.status === 'fulfilled' && r.value ? `Source ${i + 1} (${rawResults[i]?.url}):\n${r.value}` : '')
    .filter(Boolean)
    .join('\n\n---\n\n');

  const sources: SearchSource[] = rawResults.map((r, i) => ({
    title: r.title,
    url: r.url,
    snippet: r.snippet,
    relevance: Math.max(0.5, 1 - i * 0.1),
  }));

  const extractFields = req.extract_fields?.length ? `\nExtract these specific fields: ${req.extract_fields.join(', ')}` : '';

  const prompt = `You are a web research and decision assistant. A user searched for: "${req.query}"

Intent: ${INTENT_PROMPTS[intent]}${extractFields}

Here is content from the top search results:
${pageTexts || rawResults.map(r => `${r.title}: ${r.snippet}`).join('\n')}

Return ONLY valid JSON:
{
  "answer": "<comprehensive 2-5 sentence answer directly addressing the query>",
  "decision": "<proceed|caution|avoid|inconclusive>",
  "confidence": <float 0-1>,
  "key_points": ["<point 1>", "<point 2>", "<point 3>"],
  "structured_data": {
    <extract relevant structured data as key-value pairs>
  }
}

Decision guidelines:
- "proceed" — evidence strongly supports the query intent
- "caution" — mixed signals, some concerns worth noting
- "avoid" — evidence suggests this is risky, problematic or inadvisable
- "inconclusive" — insufficient data to make a clear recommendation

Rules:
- answer should directly address the query
- key_points should be 3-5 specific, actionable insights from the sources
- confidence reflects how certain you are based on source quality and consensus
- structured_data should contain the most useful extracted data
- Be factual and base decisions only on what the sources say`;

  let answer = 'No relevant results found for this query.';
  let decision: SearchDecision = 'inconclusive';
  let confidence = 0.5;
  let keyPoints: string[] = [];
  let structuredData: Record<string, unknown> = {};

  try {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error('OPENROUTER_API_KEY not set');

    const response = await fetch(OPENROUTER_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        messages: [{ role: 'user', content: prompt }],
        response_format: { type: 'json_object' },
      }),
    });

    if (!response.ok) throw new Error(`OpenRouter error: ${response.status}`);
    const data = await response.json() as { choices: { message: { content: string } }[] };
    const raw = data.choices[0].message.content ?? '{}';
    const parsed = JSON.parse(raw.replace(/```json|```/g, '').trim());
    answer = parsed.answer ?? answer;
    decision = (parsed.decision ?? 'inconclusive') as SearchDecision;
    confidence = Number(parsed.confidence ?? 0.5);
    keyPoints = (parsed.key_points ?? []) as string[];
    structuredData = parsed.structured_data ?? {};
  } catch (err) {
    logger.warn({ id, err }, 'OpenRouter extraction failed — using snippets');
    answer = rawResults.slice(0, 3).map(r => r.snippet).filter(Boolean).join(' ') || answer;
  }

  logger.info({ id, resultCount: sources.length, decision, confidence }, 'Search complete');

  return {
    id, query: req.query, intent, answer,
    decision, confidence, key_points: keyPoints,
    sources, structured_data: structuredData,
    latency_ms: Date.now() - t0, created_at: new Date().toISOString(),
  };
}
