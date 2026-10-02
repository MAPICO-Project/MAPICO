import { retryAnalysisJobResponse } from '../../../../lib/analysis.js';
import { createRoute } from '../../../../lib/route.js';
export const createHandler = createRoute({ methods: ['POST'], run: retryAnalysisJobResponse });
export default createHandler();
