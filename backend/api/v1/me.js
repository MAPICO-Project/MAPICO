import { getProfileResponse } from '../../lib/profile.js';
import { deleteAccountResponse, updateProfileResponse } from '../../lib/account.js';
import { createRoute } from '../../lib/route.js';

export const createHandler = createRoute({
  methods: ['GET', 'HEAD', 'PATCH', 'DELETE'],
  run(req, dependencies) {
    if (req.method === 'PATCH') return updateProfileResponse(req, dependencies);
    if (req.method === 'DELETE') return deleteAccountResponse(req, dependencies);
    return getProfileResponse(req, dependencies);
  }
});

export default createHandler();
