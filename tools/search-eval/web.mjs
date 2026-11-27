// Replay independently labeled result sets through the web app's parser and predicate.
import { readFileSync } from 'node:fs';
import { parseFilters, prepareFilters } from '../../Service/public/app/assets/live-filters.js';

const fixture = JSON.parse(readFileSync(new URL('./web-fixture.json', import.meta.url)));
const cases = fixture.cases.map(({ scope, query, expected }) => {
  const filter = parseFilters(query, scope, fixture.sources);
  const actual = fixture.rows[scope].filter(prepareFilters(filter)).map(row => row.id);
  const missing = expected.filter(id => !actual.includes(id));
  const unexpected = actual.filter(id => !expected.includes(id));
  return { scope, query, expected, actual, missing, unexpected, issues: filter.issues,
    passed: !missing.length && !unexpected.length && !filter.issues.length };
});
console.log(JSON.stringify({ layer: 'web parser and predicate', cases,
  passed: cases.filter(test => test.passed).length, total: cases.length }, null, 2));
