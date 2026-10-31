// The page scripts before minifying: the bodies of the parts of client.js each kind of page needs,
// joined into one function that gets the kit (built from kit.js's own source) and the page's data.
// Only tools/build-book-scripts.mjs and the tests import this; the Worker runs scripts.gen.js.

import { kit } from "./kit.js";
import { core, zones, sheetPart, bookPart, managePart, confirmedPart, codePart, forgetPart } from "./client.js";

const body = (fn) => { const s = fn.toString(); return s.slice(s.indexOf("{") + 1, s.lastIndexOf("}")); };

/** The parts each kind of page carries. */
export const PARTS = {
  profile: [core, zones],
  times: [core, zones, sheetPart, bookPart],
  manage: [core, zones, sheetPart, managePart],
  confirmed: [core, confirmedPart],
  cancelled: [core],
  code: [core, codePart],
  forget: [core, forgetPart],
};

const page = (parts) => `(function(K,D){${parts.map(body).join("\n")}})((${kit.toString()})(),JSON.parse(document.getElementById("bk").textContent));`;

/** Runs before anything paints: marks the page as scripted and, when the browser's zone or locale
 * isn't the one the server rendered in, hides the times until the page script relabels them. */
const HEAD = `(function(){var d=document.documentElement;d.classList.add("js");try{
var o=Intl.DateTimeFormat().resolvedOptions(),z=null;try{z=localStorage.getItem("bk.zone")}catch(e){}
if(d.dataset.z&&((z||o.timeZone)!==d.dataset.z||o.locale!==d.dataset.l))d.classList.add("rz")}catch(e){}})()`;

/** Every source by name: HEAD, KIT (the kit alone, for the tests) and one per kind of page. */
export function sources() {
  const out = { HEAD, KIT: `globalThis.__kit=(${kit.toString()});` };
  for (const [name, parts] of Object.entries(PARTS)) out[name] = page(parts);
  return out;
}
