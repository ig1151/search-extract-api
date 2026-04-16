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

    $('.result').each((_i, el) => {
      if (results.length >= maxResults) return;
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
