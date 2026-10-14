#pragma once
#include "p0_sql_step.h"
#include "godot_soci/query_worker.h"
namespace sqlite_api {
#include <sqlite3.h>
}
#include <soci/soci.h>
#include <soci/sqlite3/soci-sqlite3.h>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>
struct P0Scope {
    godot_soci::Completion& result;
    sqlite_api::sqlite3* db;
    P0Scope(soci::session& session, godot_soci::Completion& value):result(value) {
        p0_sql_reset();
        db=static_cast<soci::sqlite3_session_backend*>(session.get_backend())->conn_;
        sqlite_api::sqlite3_trace_v2(db,SQLITE_TRACE_PROFILE,[](unsigned,void* context,void*,void* duration)->int {
            auto& output=*static_cast<godot_soci::Completion*>(context);
            output.p0_profile_ns+=*static_cast<sqlite_api::sqlite3_int64*>(duration); ++output.p0_profiles; return 0;
        }, &result);
    }
    ~P0Scope() {
        sqlite_api::sqlite3_trace_v2(db,0,nullptr,nullptr);
        result.p0_sql_us=p0_sql_elapsed; result.p0_sql_calls=p0_sql_calls; result.p0_finished=p0_now();
    }
};
inline godot::Dictionary p0_metrics(const godot_soci::Completion& output) {
    godot::Dictionary d;
    d["sql_us"]=output.p0_sql_us; d["sql_calls"]=output.p0_sql_calls;
    d["profile_ns"]=output.p0_profile_ns; d["profile_executions"]=output.p0_profiles;
    d["prepare_us"]=output.p0_prepare_us; d["describe_us"]=output.p0_describe_us;
    d["copy_us"]=output.p0_copy_us; d["native_total_us"]=output.p0_finished-output.p0_started;
    d["queue_us"]=output.p0_started-output.p0_queued;
    d["marshal_us"]=output.p0_queued-output.p0_submitted;
    return d;
}
