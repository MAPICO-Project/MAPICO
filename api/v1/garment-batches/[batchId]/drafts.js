import { listGarmentDraftsResponse } from '../../../../lib/analysis.js';
import { createRoute } from '../../../../lib/route.js';
export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: listGarmentDraftsResponse });
export default createHandler();
