import { completeGarmentUploadResponse } from '../../../../lib/garment-batches.js';
import { createRoute } from '../../../../lib/route.js';

export const createHandler = createRoute({ methods: ['POST'], run: completeGarmentUploadResponse });
export default createHandler();
