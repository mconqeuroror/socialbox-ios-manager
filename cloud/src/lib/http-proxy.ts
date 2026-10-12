/** Keep the device contract explicit: HTTP proxy, CONNECT for HTTPS targets. */
export function validHTTPProxyURL(text: string): boolean {
  try {
    if (text.length > 4096 || /%(?![0-9a-f]{2})/i.test(text)) return false;
    const url = new URL(text);
    const authority = text.split("://")[1]?.split(/[/?#]/)[0] ?? "";
    const explicitPort = /:(\d+)$/.exec(authority)?.[1];
    const port = Number(explicitPort);
    const host = url.hostname.replace(/^\[|\]$/g, "");
    if (url.protocol !== "http:" || !explicitPort || !Number.isInteger(port) ||
        port < 1 || port > 65535 || !host || host.length > 253 ||
        !/^[a-z0-9.:-]+$/i.test(host) || (url.pathname !== "/" && url.pathname !== "") ||
        url.search || url.hash) return false;
    const username = decodeURIComponent(url.username);
    const password = decodeURIComponent(url.password);
    const credentialsPresent = authority.includes("@");
    return (!credentialsPresent || username.length > 0) && username.length <= 256 &&
      password.length <= 1024 && !/[\x00-\x1f\x7f:]/.test(username) &&
      !/[\x00-\x1f\x7f]/.test(password) && (!password || !!username);
  } catch { return false; }
}
