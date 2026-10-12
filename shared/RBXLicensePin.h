#pragma once
// Build-time deployment pins. Missing pins fail closed; no runtime key download.
// release/build tooling supplies the public PKCS#1 DER bytes and their SHA-256.
#ifndef RBX_LICENSE_PUBLIC_KEY_DER_BASE64
#define RBX_LICENSE_PUBLIC_KEY_DER_BASE64 ""
#endif
#ifndef RBX_LICENSE_KEY_ID
#define RBX_LICENSE_KEY_ID ""
#endif
