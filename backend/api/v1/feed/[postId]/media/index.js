import { createRoute } from '../../../../../lib/route.js';
import { createFeedMediaResponse } from '../../../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['POST'], run: createFeedMediaResponse });
export default createHandler();
