export function readOnly(req, res, payload, status = 200) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (!['GET', 'HEAD'].includes(req.method)) {
    res.setHeader('Allow', 'GET, HEAD');
    return res.status(405).json({ error: { code: 'METHOD_NOT_ALLOWED' } });
  }
  if (req.method === 'HEAD') return res.status(status).end();
  return res.status(status).json(payload);
}
