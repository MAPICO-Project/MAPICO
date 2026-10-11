import { createRoute } from '../../../lib/route.js';
import { createMediaUploadResponse } from '../../../lib/media.js';

export const createHandler = createRoute({ methods: ['POST'], run: createMediaUploadResponse });
export default createHandler();
