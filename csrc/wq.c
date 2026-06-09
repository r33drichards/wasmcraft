// wq — a generic SQLite query API exported from a wasm *reactor* module.
// Opens a real database file (so persistence goes through WASI file I/O), runs
// arbitrary SQL, and returns results as a US/RS-delimited string the Lua host
// decodes. The host marshals strings via wq_malloc/wq_free + linear memory.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "sqlite3.h"

#define EXPORT(n) __attribute__((export_name(n)))

#define US  0x1f  // unit separator: between fields
#define RS  0x1e  // record separator: between rows (first row = column names)
#define NULM 0x1d // a NULL field

static sqlite3 *DB = 0;
static char ERR[1024];
static char LOG[4096];
static void logcb(void *u, int code, const char *msg) {
  size_t n = strlen(LOG);
  snprintf(LOG + n, sizeof LOG - n, "(%d) %s\n", code, msg);
}

// growable result buffer
static char *RES = 0;
static size_t rlen = 0, rcap = 0;
static void rreset(void) { rlen = 0; if (RES) RES[0] = 0; }
static void rapp(const char *s, size_t n) {
  if (rlen + n + 1 > rcap) { rcap = (rlen + n + 1) * 2; RES = realloc(RES, rcap); }
  memcpy(RES + rlen, s, n); rlen += n; RES[rlen] = 0;
}
static void rappc(char c) { rapp(&c, 1); }

static int g_first;
static int cb(void *u, int argc, char **v, char **col) {
  if (g_first) {
    for (int i = 0; i < argc; i++) { if (i) rappc(US); rapp(col[i], strlen(col[i])); }
    rappc(RS); g_first = 0;
  }
  for (int i = 0; i < argc; i++) {
    if (i) rappc(US);
    if (v[i]) rapp(v[i], strlen(v[i])); else rappc(NULM);
  }
  rappc(RS);
  return 0;
}

EXPORT("wq_malloc") void *wq_malloc(int n) { return malloc(n); }
EXPORT("wq_free")   void  wq_free(void *p) { free(p); }

EXPORT("wq_log") const char *wq_log(void) { return LOG; }

EXPORT("wq_open") int wq_open(const char *path) {
  sqlite3_config(SQLITE_CONFIG_LOG, logcb, 0);
  sqlite3_initialize();
  if (DB) { sqlite3_close(DB); DB = 0; }
  int rc = sqlite3_open(path, &DB);
  if (rc != SQLITE_OK) snprintf(ERR, sizeof ERR, "%s", DB ? sqlite3_errmsg(DB) : "open failed");
  return rc;
}

EXPORT("wq_close") int wq_close(void) {
  int rc = DB ? sqlite3_close(DB) : 0;
  DB = 0;
  return rc;
}

// Execute SQL. Returns SQLITE_OK (0) on success; results retrievable via
// wq_result(), error via wq_errmsg().
EXPORT("wq_exec") int wq_exec(const char *sql) {
  rreset(); g_first = 1; ERR[0] = 0;
  char *e = 0;
  int rc = sqlite3_exec(DB, sql, cb, 0, &e);
  if (e) { snprintf(ERR, sizeof ERR, "%s", e); sqlite3_free(e); }
  return rc;
}

EXPORT("wq_result")  const char *wq_result(void)  { return RES ? RES : ""; }
EXPORT("wq_errmsg")  const char *wq_errmsg(void)  { return ERR; }
EXPORT("wq_version") const char *wq_version(void) { return sqlite3_libversion(); }
EXPORT("wq_changes") int wq_changes(void) { return DB ? sqlite3_changes(DB) : 0; }
