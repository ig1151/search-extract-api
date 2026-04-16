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
