// Every kind of data that syncs, read from the one list the app reads too (Shared/DataCatalog.json,
// docs/design/DATA-PLATFORM.md §5). Imported as JSON so wrangler bundles it and Node reads it as is.

import catalog from "../../Shared/DataCatalog.json" with { type: "json" };

/** type → {type, tier, merge, writers, seed, blobs?, day?, analytics?} */
export const CATALOG = new Map(catalog.types.map((t) => [t.type, Object.freeze({ analytics: [], ...t })]));

/** The types under the Health consent (§7). */
export const T2_TYPES = [...CATALOG.values()].filter((t) => t.tier === "T2").map((t) => t.type);
