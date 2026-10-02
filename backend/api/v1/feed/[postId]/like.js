import { createRoute } from '../../../../lib/route.js';
import { likeFeedPostResponse, unlikeFeedPostResponse } from '../../../../lib/feed.js';

export const createHandler = createRoute({ methods: ['PUT', 'DELETE'], run: (req, d) =>
  req.method === 'PUT' ? likeFeedPostResponse(req, d) : unlikeFeedPostResponse(req, d) });
export default createHandler();
