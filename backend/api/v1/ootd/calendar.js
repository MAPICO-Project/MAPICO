import { createRoute } from '../../../lib/route.js';
import { ootdCalendarResponse } from '../../../lib/outfits.js';

export const createHandler = createRoute({ methods: ['GET'], run: ootdCalendarResponse });
export default createHandler();
