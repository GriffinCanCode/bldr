module engine.caching.index.sqlite;

/// SQLite3 C API bindings for cache index
/// Links to system sqlite3 library
extern(C) nothrow @nogc:

// Result codes
enum SQLITE_OK = 0;
enum SQLITE_ERROR = 1;
enum SQLITE_BUSY = 5;
enum SQLITE_LOCKED = 6;
enum SQLITE_NOMEM = 7;
enum SQLITE_READONLY = 8;
enum SQLITE_CONSTRAINT = 19;
enum SQLITE_MISMATCH = 20;
enum SQLITE_MISUSE = 21;
enum SQLITE_ROW = 100;
enum SQLITE_DONE = 101;

// Checkpoint modes
enum SQLITE_CHECKPOINT_PASSIVE = 0;
enum SQLITE_CHECKPOINT_FULL = 1;
enum SQLITE_CHECKPOINT_RESTART = 2;
enum SQLITE_CHECKPOINT_TRUNCATE = 3;

// Destructor values
enum SQLITE_STATIC = cast(sqlite3_destructor)0;
enum SQLITE_TRANSIENT = cast(sqlite3_destructor)-1;

// Types
struct sqlite3;
struct sqlite3_stmt;
alias sqlite3_destructor = void function(void*);

// Database connection
int sqlite3_open(const(char)* filename, sqlite3** ppDb);
int sqlite3_open_v2(const(char)* filename, sqlite3** ppDb, int flags, const(char)* zVfs);
int sqlite3_close(sqlite3*);
int sqlite3_close_v2(sqlite3*);

// Error handling
int sqlite3_errcode(sqlite3*);
int sqlite3_extended_errcode(sqlite3*);
const(char)* sqlite3_errmsg(sqlite3*);
const(char)* sqlite3_errstr(int);

// SQL execution
int sqlite3_exec(
    sqlite3*,
    const(char)* sql,
    int function(void*, int, char**, char**) callback,
    void* userData,
    char** errMsg
);

// Prepared statements
int sqlite3_prepare_v2(
    sqlite3* db,
    const(char)* zSql,
    int nByte,
    sqlite3_stmt** ppStmt,
    const(char)** pzTail
);

int sqlite3_step(sqlite3_stmt*);
int sqlite3_reset(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*);
int sqlite3_clear_bindings(sqlite3_stmt*);

// Binding values
int sqlite3_bind_blob(sqlite3_stmt*, int, const(void)*, int n, sqlite3_destructor);
int sqlite3_bind_double(sqlite3_stmt*, int, double);
int sqlite3_bind_int(sqlite3_stmt*, int, int);
int sqlite3_bind_int64(sqlite3_stmt*, int, long);
int sqlite3_bind_null(sqlite3_stmt*, int);
int sqlite3_bind_text(sqlite3_stmt*, int, const(char)*, int n, sqlite3_destructor);

// Column accessors
const(void)* sqlite3_column_blob(sqlite3_stmt*, int iCol);
double sqlite3_column_double(sqlite3_stmt*, int iCol);
int sqlite3_column_int(sqlite3_stmt*, int iCol);
long sqlite3_column_int64(sqlite3_stmt*, int iCol);
const(char)* sqlite3_column_text(sqlite3_stmt*, int iCol);
int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
int sqlite3_column_count(sqlite3_stmt*);

// Column types
enum SQLITE_INTEGER = 1;
enum SQLITE_FLOAT = 2;
enum SQLITE_TEXT = 3;
enum SQLITE_BLOB = 4;
enum SQLITE_NULL = 5;

// Transaction control
int sqlite3_get_autocommit(sqlite3*);

// WAL mode
int sqlite3_wal_checkpoint(sqlite3* db, const(char)* zDb);
int sqlite3_wal_checkpoint_v2(
    sqlite3* db,
    const(char)* zDb,
    int eMode,
    int* pnLog,
    int* pnCkpt
);

// Misc
long sqlite3_last_insert_rowid(sqlite3*);
int sqlite3_changes(sqlite3*);
long sqlite3_changes64(sqlite3*);
void sqlite3_free(void*);

// Busy handling
int sqlite3_busy_timeout(sqlite3*, int ms);
int sqlite3_busy_handler(sqlite3*, int function(void*, int), void*);

