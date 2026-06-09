#include <stdio.h>
#include "sqlite3.h"

static int cb(void *u, int argc, char **argv, char **col) {
  for (int i = 0; i < argc; i++)
    printf("%s%s", argv[i] ? argv[i] : "NULL", i + 1 < argc ? " | " : "");
  printf("\n");
  return 0;
}

int main(void) {
  printf("sqlite %s in pure-Lua wasm interpreter\n", sqlite3_libversion());
  sqlite3 *db;
  char *err = 0;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    printf("open failed: %s\n", sqlite3_errmsg(db));
    return 1;
  }
  const char *ddl =
    "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, score REAL);"
    "INSERT INTO people(name,score) VALUES"
    "('alice',9.5),('bob',7.25),('carol',8.0),('dave',6.0),('erin',9.0);";
  if (sqlite3_exec(db, ddl, 0, 0, &err) != SQLITE_OK) {
    printf("ddl error: %s\n", err); sqlite3_free(err); return 1;
  }
  printf("inserted, changes=%d\n", sqlite3_changes(db));

  printf("-- SELECT name,score WHERE score>7.5 ORDER BY score DESC --\n");
  if (sqlite3_exec(db,
      "SELECT name, score FROM people WHERE score > 7.5 ORDER BY score DESC;",
      cb, 0, &err) != SQLITE_OK) {
    printf("select error: %s\n", err); sqlite3_free(err); return 1;
  }

  printf("-- aggregate: count, avg --\n");
  sqlite3_exec(db, "SELECT COUNT(*), printf('%.3f', AVG(score)) FROM people;", cb, 0, &err);

  sqlite3_close(db);
  return 0;
}
