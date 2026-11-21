// Bundles the helper into one ESM file that the app runs with its bundled Node runtime.
import { build } from "esbuild";

await build({
  entryPoints: ["src/main.mjs"],
  outfile: "dist/matter-helper.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  minify: false,
  legalComments: "none",
  // matter.js ships a Bun-only storage backend that is never used under Node: stub it out.
  plugins: [{
    name: "stub-bun",
    setup(b) {
      b.onResolve({ filter: /^bun:/ }, (args) => ({ path: args.path, namespace: "bun-stub" }));
      b.onLoad({ filter: /.*/, namespace: "bun-stub" }, () => ({
        contents: "export const constants = {}; export class Database { constructor() { throw new Error(\"Bun only\"); } }",
        loader: "js",
      }));
    },
  }],
  // Some dependencies still call require(); give the ESM bundle a working one.
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);",
  },
});
console.log("built dist/matter-helper.mjs");
