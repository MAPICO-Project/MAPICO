import { createMimicJobResponse } from '../../../lib/mimic.js';
import { createRoute } from '../../../lib/route.js';
export const createHandler = createRoute({ methods: ['POST'], run: createMimicJobResponse });
export default createHandler();
