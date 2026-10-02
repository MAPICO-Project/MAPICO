import { createRoute } from '../../../lib/route.js';
import { createOotdResponse, listOotdResponse } from '../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET', 'POST'], run: (req, d) =>
  req.method === 'GET' ? listOotdResponse(req, d) : createOotdResponse(req, d) });
export default createHandler();
