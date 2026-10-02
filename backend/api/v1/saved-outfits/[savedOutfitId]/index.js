import { createRoute } from '../../../../lib/route.js';
import { deleteSavedOutfitResponse, getSavedOutfitResponse, updateSavedOutfitResponse } from '../../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET', 'PATCH', 'DELETE'], run: (req, d) => req.method === 'GET'
  ? getSavedOutfitResponse(req, d) : req.method === 'PATCH' ? updateSavedOutfitResponse(req, d) : deleteSavedOutfitResponse(req, d) });
export default createHandler();
