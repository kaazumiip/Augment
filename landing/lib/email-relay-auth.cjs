const crypto = require('node:crypto');
// Public verification key only. The matching private credential stays on Railway.
const publicKey = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2p+PAEZJnxbuRlP8Xtdx
L+5Gh5NccdkY0s6J+ul5YVbF/SHw1UrtsBZs+5BLLtPe5guz2gg2CeGXv6avd+73
Objzs84cd8L/3f3WZZZXEydIAP6vH+Ng3wXSHgQNxmOYi6+uzKJ5yEKDdoOm6KyA
NTf8ABiVKyJ9w2f+8Y1xzDrfaA+K2YX2V+74Q++9EkUSQv7n/4OIGx0kGFUX372B
CiuMaGKbIVuDJNKDrOlQoGLup2kHsnm+kHg7Gg9oLxFYUjUMZi3gh2xNdmBfTz1r
t8PRjrQ2FYaVNUIkKMfbimkL3ww66V/DETEqKGDk4sG28cPyYVXp+VMRZzDof/3y
ZQIDAQAB
-----END PUBLIC KEY-----`;
function authenticated(body, signature, now = Date.now(), key = publicKey) {
  if (typeof body !== 'string' || Buffer.byteLength(body) > 24000 ||
      typeof signature !== 'string' || signature.length > 1024) return false;
  try {
    const payload = JSON.parse(body);
    if (payload.audience !== 'augment-verification-email' ||
        !Number.isSafeInteger(payload.timestamp) ||
        Math.abs(now - payload.timestamp) > 60000 ||
        typeof payload.nonce !== 'string' || !/^[a-f0-9]{32}$/.test(payload.nonce)) return false;
    return crypto.verify('RSA-SHA256', Buffer.from(body), key, Buffer.from(signature, 'base64'));
  } catch { return false; }
}
module.exports = { authenticated };
