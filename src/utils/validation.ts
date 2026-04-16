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
