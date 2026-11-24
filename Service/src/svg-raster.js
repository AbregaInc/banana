// BIMI logos are SVG; devices get a PNG. resvg (MPL-2.0, compiled to WebAssembly) draws it here: it
// runs no script and fetches nothing (no resource resolver is given, no system fonts are loaded), and
// sender-sources.js has refused scripts and outside references before it gets this far.

import { initWasm, Resvg } from "@resvg/resvg-wasm";

/** `load()` gives the WebAssembly module or its bytes: an import on Workers, a file on Node. */
// The module can be started once per process (initWasm refuses a second time): shared by every
// rasterizer made here.
let ready = null;

export function svgRasterizer(load) {
  return async (svg, px) => {
    ready ??= (async () => initWasm(await load()))().catch((error) => { ready = null; throw error; });
    await ready;
    const resvg = new Resvg(svg, { fitTo: { mode: "width", value: px }, font: { loadSystemFonts: false }, background: "rgba(0,0,0,0)" });
    try {
      // A BIMI logo is square. Drawn `px` wide, a tall drawing would be px × anything: refused
      // unless it is at most twice as tall as wide (and not empty).
      if (!(resvg.width > 0 && resvg.height > 0) || resvg.height / resvg.width > 2) throw new Error("svg: not a logo's shape");
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
