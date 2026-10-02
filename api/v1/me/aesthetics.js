import { replacePreferencesResponse } from '../../../lib/account.js';
import { createRoute } from '../../../lib/route.js';

export const createHandler = createRoute({ methods: ['PUT'], run: replacePreferencesResponse });
export default createHandler();
