import { createRoute } from '../../../lib/route.js';
import { createRecommendation } from '../../../lib/recommendations.js';

export const createHandler = createRoute({ methods: ['POST'], run: createRecommendation });
export default createHandler();
