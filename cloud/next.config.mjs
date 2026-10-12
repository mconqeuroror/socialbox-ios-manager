/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  async headers() {
    // These paths change when one complete signed repository is promoted.
    // APT's digest-addressed by-hash files retain the normal static policy.
    return ["redditbox", "redditbox-rootful"].flatMap((repository) => ["Packages", "Packages.gz", "Release", "InRelease", "Release.gpg", "repository.json"].map((name) => ({
      source: `/apt/${repository}/${name}`,
      headers: [{ key: "Cache-Control", value: "no-store" }],
    })));
  },
  experimental: {
    serverComponentsExternalPackages: ["bcryptjs"],
    outputFileTracingIncludes: {
      "/apt/redditbox/debs/*": ["./public/apt/redditbox/repository.json"],
      "/apt/redditbox-rootful/debs/*": ["./public/apt/redditbox-rootful/repository.json"],
    },
  },
};

export default nextConfig;
