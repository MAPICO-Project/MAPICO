import { deleteGarmentResponse, getGarmentResponse, updateGarmentResponse } from '../../../lib/garments.js';
import { createRoute } from '../../../lib/route.js';

export const createHandler = createRoute({
  methods: ['GET', 'HEAD', 'PATCH', 'DELETE'],
  run(req, dependencies) {
    if (req.method === 'PATCH') return updateGarmentResponse(req, dependencies);
    if (req.method === 'DELETE') return deleteGarmentResponse(req, dependencies);
    return getGarmentResponse(req, dependencies);
  }
});
export default createHandler();
