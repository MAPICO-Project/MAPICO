import { createRoute } from '../../../../lib/route.js';
import { completeMediaUploadResponse } from '../../../../lib/media.js';

export const createHandler = createRoute({ methods: ['POST'], run: completeMediaUploadResponse });
export default createHandler();
