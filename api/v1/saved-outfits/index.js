import { createRoute } from '../../../lib/route.js';
import { createSavedOutfitResponse, listSavedOutfitsResponse } from '../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET', 'POST'], run: (req, d) =>
  req.method === 'GET' ? listSavedOutfitsResponse(req, d) : createSavedOutfitResponse(req, d) });
export default createHandler();
