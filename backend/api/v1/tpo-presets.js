import { listTpoPresetsResponse } from '../../lib/catalog.js';
import { createRoute } from '../../lib/route.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: listTpoPresetsResponse });
export default createHandler();
