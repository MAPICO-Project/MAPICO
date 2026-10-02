import { confirmGarmentBatchResponse } from '../../../../lib/analysis.js';
import { createRoute } from '../../../../lib/route.js';
export const createHandler = createRoute({ methods: ['POST'], run: confirmGarmentBatchResponse });
export default createHandler();
