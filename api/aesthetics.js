import { readOnly } from '../lib/http.js';
import { fetchAesthetics } from '../lib/supabase.js';
export default async function handler(req, res) {
  if (!['GET','HEAD'].includes(req.method)) return readOnly(req, res, {});
  const {status,body}=await fetchAesthetics();
  return readOnly(req,res,body,status);
}
