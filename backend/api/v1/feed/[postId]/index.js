import { createRoute } from '../../../../lib/route.js';
import { deleteFeedPostResponse, getFeedPostResponse, updateFeedPostResponse } from '../../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['GET', 'PATCH', 'DELETE'], run: (req, d) =>
  req.method === 'GET' ? getFeedPostResponse(req, d) : req.method === 'PATCH' ? updateFeedPostResponse(req, d) : deleteFeedPostResponse(req, d) });
export default createHandler();
