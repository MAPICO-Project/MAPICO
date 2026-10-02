import { getAnalysisJobResponse } from '../../../lib/analysis.js';
import { createRoute } from '../../../lib/route.js';
export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: getAnalysisJobResponse });
export default createHandler();
