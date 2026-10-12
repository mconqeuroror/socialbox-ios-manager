import assert from "node:assert/strict";
import { validHTTPProxyURL } from "../src/lib/http-proxy";
import { parseProxyInput } from "../src/lib/proxies";

for (const url of ["http://proxy.example:8080", "http://proxy.example:80",
  "http://[2001:db8::1]:8080", "http://u%40x:p%2540%3A%40@proxy.example:8080"])
  assert(validHTTPProxyURL(url), url);
for (const url of ["https://proxy.example:8080", "socks5://proxy.example:1080",
  "http://proxy.example", "http://proxy.example:0", "http://proxy.example:65536",
  "http://u%0a:p@proxy.example:8080", "http://u%3a:p@proxy.example:8080",
  "http://u:%xx@proxy.example:8080", "http://:p@proxy.example:8080",
  "http://proxy.example:8080/path", "http://proxy.example:8080?q=1"])
  assert(!validHTTPProxyURL(url), url);
const input = { name: "fixture", type: "http", host: "proxy.example", port: 8080,
  username: " user ", password: "p@ss:%40" };
assert(parseProxyInput(input).ok);
const parsed = parseProxyInput(input);
assert(parsed.ok && parsed.value.username === " user ");
assert(!parseProxyInput({ ...input, type: "socks5" }).ok);
assert(!parseProxyInput({ ...input, type: "https" }).ok);
assert(!parseProxyInput({ ...input, username: "user:name" }).ok);
assert(!parseProxyInput({ ...input, password: "p\n" }).ok);
console.log("HTTP proxy contract tests passed (4 accepted / 12 rejected URLs, credential and scheme checks)");
