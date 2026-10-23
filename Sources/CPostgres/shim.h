#include <libpq-fe.h>

/* libpq defines PG_DIAG_SQLSTATE as the character literal 'C', which Swift's
 * macro importer cannot represent as an integer constant (it marks such
 * macros unavailable). This homegrown numeric spelling mirrors that field
 * code so Swift call sites can pass it to PQresultErrorField.
 */
#define WT_PG_DIAG_SQLSTATE 67
