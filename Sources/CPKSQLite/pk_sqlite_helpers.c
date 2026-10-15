#include "pk_sqlite.h"

int pk_bind_text_transient(sqlite3_stmt *stmt, int index, const char *value) {
    return sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT);
}
