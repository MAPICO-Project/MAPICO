import { updateGarmentDraftResponse } from '../../../lib/analysis.js';
import { createRoute } from '../../../lib/route.js';
export const createHandler = createRoute({ methods: ['PATCH'], run: updateGarmentDraftResponse });
export default createHandler();
