#!/usr/bin/env python3
"""SQLite-only substring-index experiment on a COPY of an isolated fixture database.
Not a replacement for Foundation localized search, repository tests, or UI timing.
"""
import argparse
import hashlib
import json
import sqlite3
import time
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--database', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--shape', choices=['all-ids', 'page-and-count'], default='all-ids')
    p.add_argument('--strategy', choices=['always', 'selective'], default='always')
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    path = args.out / 'probe.sqlite'
    db = sqlite3.connect(path)
    source = sqlite3.connect(args.database.resolve().as_uri() + '?mode=ro', uri=True)
    source.backup(db); source.close()
    db.execute('PRAGMA cache_size=-2048')
    before_bytes = path.stat().st_size
    started = time.perf_counter()
    # External content avoids duplicating bodies. This probe does not mutate notes,
    # so production migration/triggers/rollback coverage remains required separately.
    db.execute("CREATE VIRTUAL TABLE probeSearch USING fts5(transcript, episodeTitle, podcastTitle, excerpt, content='notes', content_rowid='rowid', tokenize='trigram')")
    db.execute("INSERT INTO probeSearch(probeSearch) VALUES('rebuild')")
    db.execute("CREATE INDEX probeNonASCII ON notes(searchASCII)")
    db.execute("CREATE VIRTUAL TABLE probeVocabulary USING fts5vocab(probeSearch, row)")
    db.commit()
    report = dict(scope='SQLite candidate filtering only; localized Foundation verification omitted',
                  shape=args.shape, strategy=args.strategy, sqlite=sqlite3.sqlite_version, notes=db.execute('SELECT count(*) FROM notes').fetchone()[0],
                  indexBuildMS=(time.perf_counter()-started)*1000,
                  databaseBytesBefore=before_bytes, databaseBytesAfter=path.stat().st_size,
                  cacheKiB=2048, samples=[], failures=[])
    def save():
        (args.out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    predicate = "archived=? AND (searchASCII=0 OR " + ' OR '.join(
        f"instr(lower(coalesce({field},'')),?)>0" for field in ['transcript','episodeTitle','podcastTitle','excerpt']) + ')'
    control = 'SELECT id FROM notes WHERE ' + predicate + ' ORDER BY created DESC,id'
    # UNION includes every Unicode/control row for the existing localized predicate.
    # Short/non-ASCII queries deliberately keep the original candidate scan.
    indexed = 'SELECT id FROM notes WHERE rowid IN (SELECT rowid FROM probeSearch WHERE probeSearch MATCH ? UNION SELECT rowid FROM notes WHERE searchASCII=0) AND ' + predicate + ' ORDER BY created DESC,id'
    queries = ['needle', 'NEEDLE', 'ordinary', 'project planning', 'follow-up.', 'missing', 'note 123', '"quote"', '%_wild', 'ne', 'Café', '\x00']
    for trial in range(3):
        for archived in [False, True]:
            for query in queries:
                reference = None
                for candidate in ([False, True] if trial % 2 == 0 else [True, False]):
                    ascii_query = all(32<=ord(c)<=126 for c in query)
                    eligible = len(query)>=3 and ascii_query
                    sql = indexed if candidate and eligible else control
                    params = [archived]+[query.lower()]*4
                    if not ascii_query:
                        sql = 'SELECT id FROM notes WHERE archived=? ORDER BY created DESC,id'
                        params = [archived]
                    if candidate and eligible: params.insert(0, '"'+query.replace('"','""')+'"')
                    for state in ['cache-released','warm']:
                        if state=='cache-released': db.execute('PRAGMA shrink_memory')
                        start = time.perf_counter()
                        effective_sql, effective_params = sql, params
                        uses_index = candidate and eligible
                        if uses_index and args.strategy == 'selective':
                            # A trigram document frequency bounds phrase frequency. A small,
                            # bounded lookup chooses the original scan for broad matches.
                            folded = query.lower()
                            grams = sorted({folded[i:i+3] for i in range(min(len(folded)-2, 32))})
                            frequencies = list(db.execute('SELECT doc FROM probeVocabulary WHERE term IN ('+','.join('?' for _ in grams)+')', grams))
                            estimate = min((row[0] for row in frequencies), default=0) if len(frequencies)==len(grams) else 0
                            if estimate > report['notes'] * 0.25:
                                uses_index = False
                                effective_sql, effective_params = control, [archived]+[folded]*4
                        if args.shape == 'page-and-count':
                            count_sql = effective_sql.rsplit(' ORDER BY', 1)[0].replace('SELECT id FROM notes', 'SELECT count(*) FROM notes', 1)
                            count = db.execute(count_sql, effective_params).fetchone()[0]
                            ids = [r[0] for r in db.execute(effective_sql+' LIMIT 100', effective_params)]
                        else:
                            ids = [r[0] for r in db.execute(effective_sql,effective_params)]
                            count = len(ids)
                        elapsed = (time.perf_counter()-start)*1000
                        checksum=hashlib.sha256((str(count)+'\n'+'\n'.join(ids)).encode()).hexdigest()
                        if reference is None: reference=checksum
                        elif reference != checksum: report['failures'].append(dict(trial=trial,query=repr(query),archived=archived,candidate=candidate,state=state))
                        report['samples'].append(dict(trial=trial,query=repr(query),archived=archived,candidate=candidate,indexEligible=eligible,usesIndex=uses_index,state=state,milliseconds=elapsed,count=count,pageRows=len(ids),checksum=checksum))
                save()
    report['status']='passed-candidate-equivalence' if not report['failures'] else 'failed'
    report['limitations']=['OS disk cache is not cold', 'No localized Foundation final predicate', 'No production mutation/migration coverage', 'Process memory not measured', 'Not an application performance acceptance test']
    report['plans'] = {label:list(db.execute('EXPLAIN QUERY PLAN '+sql, params)) for label,sql,params in [('control', control, [False]+['needle']*4), ('indexed', indexed, ['\"needle\"',False]+['needle']*4)]}
    save(); db.close()
    return bool(report['failures'])

if __name__ == '__main__':
    raise SystemExit(main())
