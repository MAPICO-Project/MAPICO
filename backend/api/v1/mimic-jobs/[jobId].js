import { getMimicJobResponse } from '../../../lib/mimic.js';
import { createRoute } from '../../../lib/route.js';
export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: getMimicJobResponse });
export default createHandler();
