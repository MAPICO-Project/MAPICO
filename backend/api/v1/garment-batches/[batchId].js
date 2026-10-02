import { getGarmentBatchResponse } from '../../../lib/garment-batches.js';
import { createRoute } from '../../../lib/route.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: getGarmentBatchResponse });
export default createHandler();
