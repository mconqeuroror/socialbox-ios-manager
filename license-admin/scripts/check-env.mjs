import { loadConfig } from '../lib/config.mjs';
import { x963PublicKey } from '../lib/crypto.mjs';
try {
  const config = loadConfig();
  console.log('Environment valid. No database changes made.');
  console.log(`iOS validate URL: ${config.origin}/api/validate`);
  console.log(`iOS proof key ID: ${config.proofKeyId}`);
  console.log(`iOS X9.63 public key base64: ${x963PublicKey(config.signingKey)}`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
