import { createRoute } from '../../../../lib/route.js';
import { getRecommendation } from '../../../../lib/recommendations.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: getRecommendation });
export default createHandler();
