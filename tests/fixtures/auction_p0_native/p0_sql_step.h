#pragma once
#include <chrono>
// Shared by the two adapters inside this diagnostic DLL. No production symbol/API.
inline thread_local long long p0_sql_elapsed=0, p0_sql_calls=0;
inline long long p0_now() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
inline void p0_sql_reset() { p0_sql_elapsed=0; p0_sql_calls=0; }
template<class Statement> inline int p0_sql_step(Statement* statement) {
    auto start=p0_now();
    int result=sqlite3_step(statement);
    p0_sql_elapsed+=p0_now()-start; ++p0_sql_calls;
    return result;
}
