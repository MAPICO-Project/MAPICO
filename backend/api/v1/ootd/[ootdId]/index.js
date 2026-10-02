import { createRoute } from '../../../../lib/route.js';
import { deleteOotdResponse, getOotdResponse, updateOotdResponse } from '../../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET', 'PATCH', 'DELETE'], run: (req, d) => req.method === 'GET'
  ? getOotdResponse(req, d) : req.method === 'PATCH' ? updateOotdResponse(req, d) : deleteOotdResponse(req, d) });
export default createHandler();
