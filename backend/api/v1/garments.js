import { listGarmentsResponse } from '../../lib/garments.js';
import { createRoute } from '../../lib/route.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: listGarmentsResponse });
export default createHandler();
