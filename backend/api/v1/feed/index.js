import { createRoute } from '../../../lib/route.js';
import { createFeedPostResponse, listFeedResponse } from '../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['GET', 'POST'], run: (req, d) =>
  req.method === 'GET' ? listFeedResponse(req, d) : createFeedPostResponse(req, d) });
export default createHandler();
