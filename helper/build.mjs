// Bundles the helper into one ESM file that the app runs with the Node.js installed on the Mac.
import { build } from "esbuild";

await build({
  entryPoints: ["src/main.mjs"],
  outfile: "dist/matter-helper.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  // Whitespace only: matter.js relies on class and function names, so identifiers must stay intact.
  minifyWhitespace: true,
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
