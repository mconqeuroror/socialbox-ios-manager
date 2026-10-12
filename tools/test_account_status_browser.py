#!/usr/bin/env python3
"""Portable privacy contracts; actual WebKit/CFNetwork behavior needs iOS tests."""
import ast
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "launcher/RBXAccountStatusViewController.m").read_text(encoding="utf-8")
proxy = (ROOT / "shared/RBXHTTPProxy.m").read_text(encoding="utf-8")


def objc_string(name: str) -> str:
    match = re.search(rf"{name}\s*=\s*((?:@?\"(?:\\.|[^\"\\])*\"\s*)+);", source)
    assert match, name
    return "".join(ast.literal_eval(part) for part in re.findall(r'"(?:\\.|[^"\\])*"', match[1]))


pattern = objc_string("RBXAccountUsernamePattern")
for username in ("alice", "test-user_21", "A" * 32):
    assert re.fullmatch(pattern, username), username
for username in ("", "A" * 33, "u/alice", "../admin", "a?redirect=https://evil.test", "a%2Fb", "a@b", "a\nb", "üser"):
    assert not re.fullmatch(pattern, username), username

# Exercise the exact shipped content rules against common exfiltration and
# resource paths, rather than maintaining a second independent policy.
rules = json.loads(objc_string("RBXAccountNetworkBlockRules"))
assert len(rules) == 1 and rules[0]["action"] == {"type": "block"}
assert set(rules[0]["trigger"]) == {"url-filter"}, "No resource/domain exemptions"
for resource in ("https://www.reddit.com/", "http://evil.test/", "https://evil.test/a.css",
                 "https://evil.test/font.woff", "https://evil.test/frame", "wss://evil.test/socket",
                 "file:///var/mobile/a", "data:text/html,<script>alert(1)</script>"):
    assert re.search(rules[0]["trigger"]["url-filter"], resource), resource
csp = objc_string("RBXAccountSnapshotCSP")
for directive in ("default-src 'none'", "script-src 'none'", "connect-src 'none'",
                  "frame-src 'none'", "base-uri 'none'", "form-action 'none'"):
    assert directive in csp

for invariant in (
    "nonPersistentDataStore", "allowsContentJavaScript = NO", "allowsLinkPreview = NO",
    "ephemeralSessionConfiguration", "connectionProxyDictionary = proxySettings",
    "HTTPCookieStorage = nil", "HTTPShouldSetCookies = NO", "HTTPShouldHandleCookies = NO",
    "URLCredentialStorage = nil", "URLCache = nil", "timeoutIntervalForResource = 30",
    "waitsForConnectivity = NO", "response.expectedContentLength >",
    "data.length > RBXAccountMaximumBytes - self.responseData.length",
    "++self.redirectCount > RBXAccountMaximumRedirects", "RBXHTTPProxyDelegate alloc",
    "completionHandler([self anonymousRequestForURL:request.URL])",
    "NSURLSessionAuthChallengeCancelAuthenticationChallenge", "invalidateAndCancel",
    "navigationAction.targetFrame.isMainFrame", "WKNavigationActionPolicyCancel",
    "404 is inconclusive", "not proof of a shadowban",
):
    assert invariant in source, invariant
assert source.index("addContentRuleList:rules") < source.index("self.networkBlockerReady = YES")
assert source.index("if (!proxySettings.count)") < source.index("dataTaskWithRequest:request")
assert '@[@"reddit.com", @"www.reddit.com"]' in source
assert 'isEqualToString:@"https"' in source
assert 'parts.port.integerValue == 443' in source
assert '!parts.user && !parts.password && !parts.fragment' in source
assert 'isEqualToString:@"about:blank"' in source
assert source.count("[self.task resume]") == 1
for forbidden in ("loadRequest:", "openURL:", "SFSafariViewController", "evaluateJavaScript:",
                  "document.cookie", "accessKey:", "deviceToken", "Bearer ", "rotationURL", "rotateAndActivate"):
    assert forbidden not in source, forbidden
assert "DIRECT" not in re.search(r'@"function FindProxyForURL.*?;', proxy)[0]

print("account status browser privacy contracts passed (WebKit/CFNetwork execution requires iOS)")
