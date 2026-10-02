import { createRoute } from '../../../lib/route.js';
import { closetStatisticsResponse } from '../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET'], run: closetStatisticsResponse });
export default createHandler();
