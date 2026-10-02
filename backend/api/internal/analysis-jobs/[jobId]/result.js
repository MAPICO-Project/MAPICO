import { createAnalysisCallbackHandler } from '../../../../lib/analysis-callback.js';

export const config = { api: { bodyParser: false } };
export const createHandler = createAnalysisCallbackHandler;
export default createHandler();
