import { createRoute } from '../../../lib/route.js';
import { listLikedPostsResponse } from '../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['GET'], run: listLikedPostsResponse });
export default createHandler();
