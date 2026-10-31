// Spike for the data-safety review of docs/design/MAIL-ENGINE.md.
//
// Mode 1 (default): "accept an action" is two commits in two WAL files with no cross-file
// transaction (design 4.2, 6.4). A child process commits the intent row (synchronous=FULL,
// fullfsync=ON), signals the parent through a pipe, and only then begins the index commit.
// The parent SIGKILLs the child the moment the signal arrives. The parent then reopens both
// files on a fresh connection and reports what launch-time recovery would see.
//
// Mode 2 ("seq"): the delivery race of design 6.2/6.3/6.5. A label_intent row is marked in
// flight (seq 5). Before its 2xx arrives, an undo upserts the same primary key with the
// opposite `want` and seq 6 (6.3: "a second assertion for the same key overwrites the first").
// The 2xx handler then marks the row settling. Shown twice: keyed by primary key alone (the
// undo is marked delivered though it never left the device) and keyed by primary key AND the
// seq that was sent (the undo stays pending). Pure SQL, no processes.
//
// Build: cc -O1 crash_between_commits.c -lsqlite3 -o crash_between_commits
// Run:   ./crash_between_commits <dir>        (mode 1)
//        ./crash_between_commits <dir> seq    (mode 2)
// Runtime is well under a second of CPU.

#include <sqlite3.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void die(const char *what, sqlite3 *db) {
    fprintf(stderr, "fatal: %s: %s\n", what, db ? sqlite3_errmsg(db) : "?");
    exit(2);
}

static void exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "fatal: %s\n  in: %s\n", err, sql);
        exit(2);
    }
}

static sqlite3 *open_db(const char *path, const char *pragmas) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK)
        die("open", db);
    exec(db, "PRAGMA journal_mode=WAL;");
    exec(db, pragmas);
    return db;
}

static int count(sqlite3 *db, const char *sql) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) die("prepare", db);
    int n = -1;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return n;
}

static const char *intent_pragmas = "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA wal_autocheckpoint=0;";
static const char *index_pragmas  = "PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=0;";

static const char *intent_schema =
    "CREATE TABLE IF NOT EXISTS label_intent("
    " account TEXT NOT NULL, gmail_msg_id TEXT NOT NULL, label_ref TEXT NOT NULL,"
    " want INTEGER NOT NULL, seq INTEGER NOT NULL, group_id TEXT NOT NULL,"
    " state INTEGER NOT NULL DEFAULT 0,"
    " PRIMARY KEY(account, gmail_msg_id, label_ref)) WITHOUT ROWID;"
    "CREATE TABLE IF NOT EXISTS action_group(group_id TEXT PRIMARY KEY, before BLOB NOT NULL);";

static const char *index_schema =
    "CREATE TABLE IF NOT EXISTS overlay(msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL,"
    " want INTEGER NOT NULL, PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;"
    "CREATE TABLE IF NOT EXISTS thread(thread_pk INTEGER PRIMARY KEY, labels TEXT, pending INTEGER NOT NULL DEFAULT 0);";

static int mode_crash(const char *dir) {
    char intent_path[1024], index_path[1024];
    snprintf(intent_path, sizeof intent_path, "%s/intent.sqlite", dir);
    snprintf(index_path, sizeof index_path, "%s/index.sqlite", dir);
    unlink(intent_path); unlink(index_path);
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s-wal", intent_path); unlink(tmp);
    snprintf(tmp, sizeof tmp, "%s-shm", intent_path); unlink(tmp);
    snprintf(tmp, sizeof tmp, "%s-wal", index_path); unlink(tmp);
    snprintf(tmp, sizeof tmp, "%s-shm", index_path); unlink(tmp);

    {   // schema, then close so the child starts from files on disk
        sqlite3 *a = open_db(intent_path, intent_pragmas); exec(a, intent_schema); sqlite3_close(a);
        sqlite3 *b = open_db(index_path, index_pragmas);   exec(b, index_schema);  sqlite3_close(b);
        // seed one thread row so the index commit has something to rewrite
        b = open_db(index_path, index_pragmas);
        exec(b, "INSERT INTO thread(thread_pk, labels, pending) VALUES (7, ',1,', 0);");
        sqlite3_close(b);
    }

    int fds[2];
    if (pipe(fds) != 0) { perror("pipe"); return 2; }
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }

    if (child == 0) {
        close(fds[0]);
        fprintf(stderr, "child: opening\n");
        sqlite3 *intent = open_db(intent_path, intent_pragmas);
        fprintf(stderr, "child: intent open\n");
        sqlite3 *index  = open_db(index_path, index_pragmas);
        fprintf(stderr, "child: index open\n");
        // Step 1 of 6.4: one intent transaction, full fsync. "From here the action survives anything."
        exec(intent, "BEGIN IMMEDIATE;"
                     "INSERT INTO label_intent VALUES ('a@x','m1','INBOX',0,1,'g1',0);"
                     "INSERT INTO label_intent VALUES ('a@x','m2','INBOX',0,2,'g1',0);"
                     "INSERT INTO action_group VALUES ('g1', X'5B5D');"
                     "COMMIT;");
        // The commit has returned: tell the parent, which kills us before step 2 lands.
        fprintf(stderr, "child: intent committed\n");
        if (write(fds[1], "c", 1) != 1) { perror("child write"); _exit(3); }
        // Step 2 of 6.4: the index transaction. Begin it, write, and loiter before COMMIT so the
        // kill lands inside it (the realistic case: the two commits are 3 ms apart on this Mac).
        exec(index, "BEGIN IMMEDIATE;"
                    "INSERT INTO overlay VALUES (7, 1, 0);"
                    "UPDATE thread SET labels = ',', pending = 1 WHERE thread_pk = 7;");
        usleep(200 * 1000);
        exec(index, "COMMIT;");
        _exit(0);   // not reached: the parent kills us
    }

    close(fds[1]);
    char byte = 0;
    ssize_t got = read(fds[0], &byte, 1);
    if (got != 1) { fprintf(stderr, "child never signalled\n"); return 2; }
    kill(child, SIGKILL);
    int status = 0;
    waitpid(child, &status, 0);
    printf("child signalled 'intent committed' then was SIGKILLed; status=%s\n",
           WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL ? "killed by SIGKILL" : "other");

    // Launch-time recovery: fresh connections, which replay each file's own WAL.
    sqlite3 *intent = open_db(intent_path, intent_pragmas);
    sqlite3 *index  = open_db(index_path, index_pragmas);
    int intents = count(intent, "SELECT count(*) FROM label_intent;");
    int groups  = count(intent, "SELECT count(*) FROM action_group;");
    int overlay = count(index,  "SELECT count(*) FROM overlay;");
    int pending = count(index,  "SELECT pending FROM thread WHERE thread_pk = 7;");
    const char *labels = NULL;
    {
        sqlite3_stmt *st = NULL;
        sqlite3_prepare_v2(index, "SELECT labels FROM thread WHERE thread_pk = 7;", -1, &st, NULL);
        if (sqlite3_step(st) == SQLITE_ROW) labels = strdup((const char *)sqlite3_column_text(st, 0));
        sqlite3_finalize(st);
    }
    printf("after reopen: intent.label_intent=%d intent.action_group=%d | index.overlay=%d index.thread.labels='%s' index.thread.pending=%d\n",
           intents, groups, overlay, labels ? labels : "?", pending);
    int behind = (intents == 2 && overlay == 0);
    printf("index is %s the intent\n", behind ? "BEHIND" : "not behind");
    printf("what the design does about it (6.4): overlay is emptied and refilled from label_intent at launch -> overlay rows become %d, thread row re-summarised\n", intents);
    sqlite3_close(intent); sqlite3_close(index);
    return behind ? 0 : 1;
}

static void show_row(sqlite3 *db, const char *tag) {
    sqlite3_stmt *st = NULL;
    sqlite3_prepare_v2(db, "SELECT want, seq, state FROM label_intent WHERE gmail_msg_id='m1' AND label_ref='INBOX';", -1, &st, NULL);
    if (sqlite3_step(st) == SQLITE_ROW)
        printf("  %-44s want=%d seq=%d state=%d (%s)\n", tag,
               sqlite3_column_int(st, 0), sqlite3_column_int(st, 1), sqlite3_column_int(st, 2),
               sqlite3_column_int(st, 2) == 0 ? "pending" : sqlite3_column_int(st, 2) == 1 ? "in flight" : sqlite3_column_int(st, 2) == 2 ? "settling" : "failed");
    sqlite3_finalize(st);
}

static int mode_seq(const char *dir) {
    char path[1024];
    snprintf(path, sizeof path, "%s/seq.sqlite", dir);
    unlink(path);
    sqlite3 *db = open_db(path, intent_pragmas);
    exec(db, intent_schema);

    for (int guarded = 0; guarded < 2; guarded++) {
        printf("%s 2xx handler:\n", guarded ? "seq-guarded" : "primary-key-only");
        exec(db, "DELETE FROM label_intent;");
        // Archive: INBOX absent on m1, seq 5. The driver marks it in flight and sends.
        exec(db, "INSERT INTO label_intent VALUES ('a@x','m1','INBOX',0,5,'g1',1);");
        show_row(db, "archive sent, in flight");
        // Undo arrives while the request is on the wire: same key, opposite want, higher seq (6.3).
        exec(db, "INSERT OR REPLACE INTO label_intent VALUES ('a@x','m1','INBOX',1,6,'g1',0);");
        show_row(db, "undo accepted (overwrites the key)");
        // The archive's 2xx arrives. The handler marks "the row" settling.
        if (!guarded) {
            exec(db, "UPDATE label_intent SET state=2 WHERE account='a@x' AND gmail_msg_id='m1' AND label_ref='INBOX';");
        } else {
            exec(db, "UPDATE label_intent SET state=2 WHERE account='a@x' AND gmail_msg_id='m1' AND label_ref='INBOX' AND seq=5;");
        }
        show_row(db, "archive's 2xx handled");
        int state = count(db, "SELECT state FROM label_intent WHERE gmail_msg_id='m1' AND label_ref='INBOX';");
        int want  = count(db, "SELECT want  FROM label_intent WHERE gmail_msg_id='m1' AND label_ref='INBOX';");
        if (state == 2 && want == 1)
            printf("  -> the undo (want INBOX present) is marked settling: it will be deleted after its echo window and was NEVER SENT. Gmail keeps the archive; this device shows the conversation back in the inbox until the overlay row is dropped, then it vanishes. The undo is lost.\n");
        else
            printf("  -> the undo stays pending (want=%d, state=%d) and is delivered on the next drain. Correct.\n", want, state);
    }
    sqlite3_close(db);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dir> [seq]\n", argv[0]); return 2; }
    if (argc >= 3 && strcmp(argv[2], "seq") == 0) return mode_seq(argv[1]);
    return mode_crash(argv[1]);
}
