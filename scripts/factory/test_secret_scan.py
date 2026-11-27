import base64
import codecs
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import secret_scan

ROOT = Path(__file__).resolve().parents[2]
# Assembled here so that this file holds no secret-like string.
BODY = "aB3dE5fG7hJ9kL1" + "mN3pQ5rS7tU9vW1xY3z5A"
TOKEN = "gh" + "p_" + BODY
SECRETS = {
    "github classic": TOKEN,
    "github fine-grained": "github" + "_pat_" + "11ABCDEFG0" + BODY,
    "anthropic": "sk-" + "ant-oat01-" + BODY,
    "aws": "AK" + "IAIOSFODNN7EXAMPLQ",
    "private key": "-----BEGIN RSA " + "PRIVATE KEY-----",
    "jwt": "ey" + "JhbGciOiJIUzI1NiJ9." + "ey" + "JzdWIiOiIxMjM0NTYifQ.abc",
    "slack": "xox" + "b-123456789012-abcdef",
    "url password": "rediss://admin:" + "hunter2hunter2" + "@host:6380",
    "assignment": 'clientSecret = "' + "a1b2c3d4e5f6g7h8i9" + '"',
    "bearer": "Authorization: " + "Bearer " + "abcdefghijklmnop1234",
    "random": "Zx8Kq2Lw9Rt4" + "Vb7Nm3Cd6Fg1Hj5",
}


class SecretTest(unittest.TestCase):
    def test_kinds(self):
        for name, value in SECRETS.items():
            with self.subTest(name):
                self.assertTrue(secret_scan.found(f"before\nx = {value}\nafter\n"))

    def test_encodings_of_one_token(self):
        raw = TOKEN.encode()
        encoded = base64.b64encode(raw).decode()
        encodings = {
            "base64": encoded,
            "base64 unaligned": "xy" + encoded,
            "base64 inside a value": base64.b64encode(b"k=" + raw + b";").decode(),
            "base64 url": base64.urlsafe_b64encode(b"\xfb\xff" + raw).decode(),
            "base64 twice": base64.b64encode(encoded.encode()).decode(),
            "base64 wrapped": "\n".join(encoded[i : i + 10] for i in range(0, 60, 10)),
            "base32": base64.b32encode(raw).decode(),
            "hex": raw.hex(),
            "hex upper": raw.hex().upper(),
            "hex unaligned": "a" + raw.hex(),
            "percent": "".join(f"%{b:02x}" for b in raw),
            "backslash x": "".join(f"\\x{b:02x}" for b in raw),
            "backslash u": "".join(f"\\u00{b:02x}" for b in raw),
            "haskell decimal": "".join(f"\\{b}" for b in raw),
            "html": "".join(f"&#{b};" for b in raw),
            "byte list": ", ".join(map(str, raw)),
            "hex byte list": ", ".join(map(hex, raw)),
            "reversed": TOKEN[::-1],
            "rot13": codecs.encode(TOKEN, "rot13"),
            "fullwidth": "".join(chr(ord(c) + 0xFEE0) for c in TOKEN),
            "concatenated": '"gh" <> "p_" <> "' + BODY[:9] + '"\n  <> "' + BODY[9:] + '"',
            "one per line": "\n".join(f"  '{c}'," for c in TOKEN),
            "base85": base64.b85encode(raw).decode(),
            "base85 unaligned": "zz" + base64.b85encode(raw).decode(),
            "ascii85": base64.a85encode(raw).decode(),
            "glued": "abc" + TOKEN + "def",
        }
        for name, value in encodings.items():
            with self.subTest(name):
                self.assertTrue(secret_scan.found(f"x = {value}\n"))

    def test_long_hexadecimal_values(self):
        for length in (32, 40, 48, 64, 128):
            value = ("3f9a1c77e0b24d58" * 8)[:length]
            for text in (value, value.upper(), f"k={value};", f"0x{value}", f"'{value}'"):
                with self.subTest(text):
                    self.assertTrue(secret_scan.found(text))

    def test_split_private_key_header(self):
        header = '"-----BEG' + 'IN " <> "PRIV' + 'ATE " <> "KEY-----"'
        self.assertTrue(secret_scan.found(header))

    def test_ordinary_code_passes(self):
        for path in (
            "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Client.hs",
            "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Internal/CommandMetadata.hs",
            "README.md",
            "Makefile",
            "redis-client.cabal",
            "scripts/factory/gate.py",
            "docs/factory.md",
            "test/LibraryE2E/ResilienceTests.hs",
        ):
            with self.subTest(path):
                self.assertFalse(secret_scan.found((ROOT / path).read_text(encoding="utf-8")))
        for text in (
            "commit 1b61536aa598, run 12345678901234567890",
            "0" * 64,
            "redis://user:password@localhost",
            "multiplexerBackpressureConfigurationSpec2",
        ):
            with self.subTest(text):
                self.assertFalse(secret_scan.found(text))


if __name__ == "__main__":
    unittest.main()
