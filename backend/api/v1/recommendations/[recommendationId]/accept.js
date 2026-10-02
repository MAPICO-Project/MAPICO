import { createRoute } from '../../../../lib/route.js';
import { acceptRecommendation } from '../../../../lib/recommendations.js';

export const createHandler = createRoute({ methods: ['POST'], run: acceptRecommendation });
export default createHandler();
