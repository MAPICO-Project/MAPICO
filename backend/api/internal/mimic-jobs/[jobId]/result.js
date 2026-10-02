import { createMimicCallbackHandler } from '../../../../lib/mimic-callback.js';

export const config = { api: { bodyParser: false } };
export const createHandler = createMimicCallbackHandler;
export default createHandler();
