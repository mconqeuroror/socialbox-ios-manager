#!/usr/bin/env python3
"""Generate deployment signing material or a public-only iOS compile-time pin.

Private material is never printed and is not required to build the phone app.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def openssl_run(executable, *args, data=None):
    result = subprocess.run([executable, *args], input=data, capture_output=True)
    if result.returncode:
        raise ValueError("OpenSSL rejected the key or could not write it")
    return result.stdout


def rsa_bits(der):
    def tlv(data, pos, tag):
        if pos >= len(data) or data[pos] != tag:
            raise ValueError("Expected a PKCS#1 RSA public key")
        pos += 1
        length = data[pos]
        pos += 1
        if length & 128:
            count = length & 127
            if not 1 <= count <= 4 or pos + count > len(data):
                raise ValueError("Invalid DER length")
            length = int.from_bytes(data[pos:pos + count], "big")
            pos += count
        if pos + length > len(data):
            raise ValueError("Truncated DER")
        return data[pos:pos + length], pos + length
    sequence, end = tlv(der, 0, 48)
    if end != len(der):
        raise ValueError("Trailing public-key data")
    modulus, pos = tlv(sequence, 0, 2)
    exponent, end = tlv(sequence, pos, 2)
    if end != len(sequence) or int.from_bytes(exponent, "big") != 65537:
        raise ValueError("RSA public exponent must be 65537")
    bits = int.from_bytes(modulus, "big").bit_length()
    if not 2048 <= bits <= 4096:
        raise ValueError("RSA signing key must be 2048–4096 bits")
    return bits


def pin(public_key, output, openssl):
    public = Path(public_key).read_bytes()
    if len(public) > 16384 or b"PRIVATE KEY" in public:
        raise ValueError("Build accepts a public PEM key only; keep private signing material in cloud secrets")
    der = openssl_run(openssl, "rsa", "-pubin", "-RSAPublicKey_out", "-outform", "DER", data=public)
    rsa_bits(der)
    kid = hashlib.sha256(der).hexdigest()
    text = ('// Generated public-only deployment pin. Never edit manually.\n#pragma once\n'
            f'#define RBX_LICENSE_PUBLIC_KEY_DER_BASE64 "{base64.b64encode(der).decode()}"\n'
            f'#define RBX_LICENSE_KEY_ID "{kid}"\n')
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, mode="w", encoding="utf-8", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return kid


def generate(directory, openssl):
    destination = Path(directory)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    private, public = destination / "license-private.pem", destination / "license-public.pem"
    if private.exists() or public.exists():
        raise ValueError("Signing files already exist; refusing to rotate or overwrite a deployment key")
    # Exclusive creation reserves the destination. Never replace an existing key.
    fd = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    try:
        openssl_run(openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", str(private))
        pem = openssl_run(openssl, "rsa", "-in", str(private), "-RSAPublicKey_out")
        with public.open("xb") as handle:
            handle.write(pem)
    except Exception:
        # Retain an existing successfully generated private key for explicit recovery.
        if private.stat().st_size == 0:
            private.unlink()
        raise
    return private, public


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", default=os.environ.get("OPENSSL", "openssl"))
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("generate")
    create.add_argument("--directory", required=True)
    compile_pin = sub.add_parser("pin")
    compile_pin.add_argument("--public-key", required=True)
    compile_pin.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            private, public = generate(args.directory, args.openssl)
            print(f"Private signing key saved at {private}. Store its contents only in cloud LICENSE_SIGNING_PRIVATE_KEY.")
            print(f"Public build key saved at {public}. Set LICENSE_PUBLIC_KEY_FILE to this path on the Mac.")
        else:
            print("Pinned license public key: " + pin(args.public_key, args.output, args.openssl))
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
