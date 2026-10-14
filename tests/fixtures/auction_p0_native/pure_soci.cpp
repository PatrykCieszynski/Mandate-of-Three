// Standalone quick comparison. No Godot, worker, dispatcher, or production API.
#include <soci/soci.h>
#include <soci/sqlite3/soci-sqlite3.h>
#include "p0_sql_step.h"
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
struct Binding { std::string name,text; char type; long long integer=0; double real=0; };
int main(int argc,char**argv) try {
    if(argc!=4) throw std::runtime_error("usage: pure_soci database transfer-file samples");
    std::ifstream input(argv[2]); std::string sql,line;
    if(!std::getline(input,sql)||sql.empty())throw std::runtime_error("missing SQL transfer input");
    std::deque<Binding> bindings;
    while(std::getline(input,line)&&!line.empty()) {
        auto a=line.find('\t'),b=line.find('\t',a+1);
        if(a==std::string::npos||b==std::string::npos||b!=a+2)throw std::runtime_error("invalid binding transfer input");
        Binding arg;arg.name=line.substr(0,a);arg.type=line[a+1];arg.text=line.substr(b+1);
        if(arg.type=='i')arg.integer=std::stoll(arg.text);
        if(arg.type=='d')arg.real=std::stod(arg.text);
        bindings.push_back(arg);
    }
    std::vector<std::string> expected;
    while(std::getline(input,line))if(!line.empty())expected.push_back(line);
    soci::session session(soci::sqlite3,std::string("dbname='")+argv[1]+"' readonly=true timeout=1");
    session<<"PRAGMA query_only=ON;";
    std::string version;session<<"SELECT sqlite_version()",soci::into(version);
    std::cout<<"version,"<<version<<"\nphase,iteration,rows,wall_us,sql_us,sql_calls\n";
    const int samples=std::stoi(argv[3]);
    if(samples<1)throw std::runtime_error("at least one measured sample is required");
    bool budget_failed=false;
    for(int n=-3;n<samples;++n) {
        p0_sql_reset();auto start=p0_now();std::vector<std::string> actual;
        {
            soci::row row;soci::statement statement(session);statement.alloc();statement.prepare(sql);
            statement.exchange(soci::into(row));
            for(auto&arg:bindings) {
                if(arg.type=='i')statement.exchange(soci::use(arg.integer,arg.name));
                else if(arg.type=='d')statement.exchange(soci::use(arg.real,arg.name));
                else statement.exchange(soci::use(arg.text,arg.name));
            }
            statement.define_and_bind();statement.execute();
            while(statement.fetch()) {
                // Copy every field into standalone C++ values, not just count fetches.
                std::vector<std::string> values;
                for(std::size_t c=0;c<row.size();++c) {
                    if(row.get_indicator(c)==soci::i_null){values.emplace_back();continue;}
                    auto type=row.get_properties(c).get_db_type();
                    if(type==soci::db_string)values.push_back(row.get<std::string>(c));
                    else if(type==soci::db_double)values.push_back(std::to_string(row.get<double>(c)));
                    else values.push_back(std::to_string(row.get<long long>(c)));
                }
                actual.push_back(row.get<std::string>("offer_id")+"\t"+std::to_string(row.get<long long>("price_yang")));
            }
        }
        auto wall=p0_now()-start;
        if(wall>2000000||p0_sql_elapsed>2000000)budget_failed=true;
        if(actual!=expected)throw std::runtime_error("ordered offer/price parity failed");
        if(n==-3||n>=0)std::cout<<(n==-3?"connection_cold":"warm")<<","<<n<<","<<actual.size()<<","<<wall<<","<<p0_sql_elapsed<<","<<p0_sql_calls<<"\n";
    }
    return budget_failed?2:0;
} catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}
