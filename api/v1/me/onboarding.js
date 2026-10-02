import { saveOnboardingResponse } from '../../../lib/account.js';
import { createRoute } from '../../../lib/route.js';

export const createHandler = createRoute({ methods: ['PUT'], run: saveOnboardingResponse });
export default createHandler();
