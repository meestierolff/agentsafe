/** @type {import('next').NextConfig} */
const nextConfig = {
  // One address for the site: www sends visitors to the bare domain.
  async redirects() {
    return [
      {
        source: "/:path*",
        has: [{ type: "host", value: "www.safeagent.live" }],
        destination: "https://safeagent.live/:path*",
        permanent: true,
      },
    ];
  },
};

export default nextConfig;
