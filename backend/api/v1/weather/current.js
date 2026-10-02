import { createRoute } from '../../../lib/route.js';
import { getCurrentWeather } from '../../../lib/weather.js';

export const createHandler = createRoute({ methods: ['GET', 'HEAD'], run: getCurrentWeather });
export default createHandler();
