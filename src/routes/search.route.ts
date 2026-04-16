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
