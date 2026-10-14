#include <stdio.h>
#include <sqlite3.h>
int main(void) {
    printf("P0_LINK_RUNTIME version=%s SQLITE_DEBUG=%d\n",sqlite3_libversion(),sqlite3_compileoption_used("DEBUG"));
    return 0;
}
