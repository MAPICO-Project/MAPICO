import { getProfileResponse } from '../../lib/profile.js';
import { updateProfileResponse } from '../../lib/account.js';
import { createRoute } from '../../lib/route.js';

export const createHandler = createRoute({
  methods: ['GET', 'HEAD', 'PATCH'],
  run(req, dependencies) {
    return req.method === 'PATCH' ? updateProfileResponse(req, dependencies) : getProfileResponse(req, dependencies);
  }
});

export default createHandler();
