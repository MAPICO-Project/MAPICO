import { createAnalysisJobResponse } from '../../../../lib/analysis.js';
import { createRoute } from '../../../../lib/route.js';
export const createHandler = createRoute({ methods: ['POST'], run: createAnalysisJobResponse });
export default createHandler();
