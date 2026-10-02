import { listAestheticsResponse } from '../lib/catalog.js';
import { createRoute } from '../lib/route.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: listAestheticsResponse });
export default createHandler();
