// Node LTS security floor: October 21, 2026. Workers does not import this module.
export function assertSupportedNode(version = process.versions.node) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!match || Number(match[1]) !== 24 || Number(match[2]) < 22 ||
      (Number(match[2]) === 22 && Number(match[3]) < 1)) {
    throw new Error(`Unsupported Node.js ${version}. Banana requires Node.js >=24.22.1 <25 (October 2026 security fixes).`);
  }
}

assertSupportedNode();
