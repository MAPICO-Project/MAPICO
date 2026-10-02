import { createRoute } from '../../../lib/route.js';
import { listMyPostsResponse } from '../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['GET'], run: listMyPostsResponse });
export default createHandler();
