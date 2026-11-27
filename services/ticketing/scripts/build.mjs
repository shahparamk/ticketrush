// Bundles each Lambda handler into dist/<name>/index.mjs (one zip per function later).
import { build } from "esbuild";

// Add new handlers here as they're written (session, authorizer, hold, ...)
const handlers = ["read"];

await build({
  entryPoints: Object.fromEntries(handlers.map((name) => [`${name}/index`, `src/handlers/${name}.ts`])),
  bundle: true,
  platform: "node",
  target: "node24",
  format: "esm",
  outdir: "dist",
  outExtension: { ".js": ".mjs" },
  sourcemap: true,
  minify: true, // smaller bundle = faster cold starts; the source map keeps stack traces readable
  // Parts of the AWS SDK still call require(); in an ES module bundle that needs a real require function
  banner: {
    js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);",
  },
  logLevel: "info",
});