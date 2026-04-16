export type SearchIntent = 'summary' | 'facts' | 'news' | 'research' | 'extract';
export type SearchDecision = 'proceed' | 'caution' | 'avoid' | 'inconclusive';

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
  decision: SearchDecision;
  confidence: number;
  key_points: string[];
  sources: SearchSource[];
  structured_data: Record<string, unknown>;
  latency_ms: number;
  created_at: string;
}

export interface BatchRequest {
  searches: SearchRequest[];
}