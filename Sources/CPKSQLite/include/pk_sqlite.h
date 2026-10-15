#ifndef PK_SQLITE_H
#define PK_SQLITE_H

/*
** The public umbrella for the vendored SQLite library. The prefix macro header
** must come first so every `sqlite3_*` declaration below is renamed to
** `pk_sqlite3_*`.
*/
#include "../pk_sqlite_prefix.h"
#include "../sqlite3.h"

/*
** Binds a Swift-owned string without relying on the C macro `SQLITE_TRANSIENT`,
** which the Clang importer cannot represent. The copy flag tells SQLite to make
** its own copy of the bytes before returning.
*/
int pk_bind_text_transient(sqlite3_stmt *stmt, int index, const char *value);

#endif /* PK_SQLITE_H */
