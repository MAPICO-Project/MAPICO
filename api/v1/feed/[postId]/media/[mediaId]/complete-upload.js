import { createRoute } from '../../../../../../lib/route.js';
import { completeFeedMediaResponse } from '../../../../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['POST'], run: completeFeedMediaResponse });
export default createHandler();
