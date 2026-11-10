// BIMI logos are SVG; devices get a PNG. resvg (MPL-2.0, compiled to WebAssembly) draws it here: it
// runs no script and fetches nothing (no resource resolver is given, no system fonts are loaded), and
// sender-sources.js has refused scripts and outside references before it gets this far.

import { initWasm, Resvg } from "@resvg/resvg-wasm";

/** `load()` gives the WebAssembly module or its bytes: an import on Workers, a file on Node. */
export function svgRasterizer(load) {
  let ready = null;
  return async (svg, px) => {
    ready ??= (async () => initWasm(await load()))().catch((error) => { ready = null; throw error; });
    await ready;
    const resvg = new Resvg(svg, { fitTo: { mode: "width", value: px }, font: { loadSystemFonts: false }, background: "rgba(0,0,0,0)" });
    try {
      const rendered = resvg.render();
      try { return rendered.asPng(); } finally { rendered.free?.(); }
    } finally { resvg.free?.(); }
  };
}

/** On Node (the service's own runtime, and the tests): the module's bytes from node_modules. */
export async function nodeSvgRasterizer() {
  const { readFile } = await import("node:fs/promises");
  const { createRequire } = await import("node:module");
  const path = createRequire(import.meta.url).resolve("@resvg/resvg-wasm/index_bg.wasm");
  return svgRasterizer(() => readFile(path));
}
