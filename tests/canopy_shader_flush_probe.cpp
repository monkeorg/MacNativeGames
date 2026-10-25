// Original IR collections through the actual protected Cross invalidation API.
// A fresh compiler is destroyed after every interruption; no partially mutated
// production compiler is reused. No game shader or substitute compiler.
#include "canopy_cross_budget.hpp"
#include "spirv_msl.hpp"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <exception>
#include <vector>

class FlushCompiler : public spirv_cross::CompilerMSL {
    unsigned kind;
public:
    explicit FlushCompiler(unsigned target) : CompilerMSL(std::vector<uint32_t>{
        0x07230203,0x10000,0,5,0,0x20011,1,0x3000e,0,1,
        0x5000f,5,3,0x6e69616d,0,0x60010,3,17,1,1,1,
        0x20013,1,0x30021,2,1,0x50036,1,3,0,2,0x200f8,4,0x100fd,0x10038}),kind(target) {
        assert(kind<10);ir.set_id_bounds(256);
        auto &type=set<spirv_cross::SPIRType>(10,spv::OpTypeInt);type.basetype=spirv_cross::SPIRType::UInt;
        auto &function=set<spirv_cross::SPIRFunction>(11,1,0,2);current_function=&function;
        auto &expression=set<spirv_cross::SPIRExpression>(12,"original",10,false);expression.buffer_pointer=true;
        auto &variable=set<spirv_cross::SPIRVariable>(13,10,spv::StorageClassPrivate);
        // Use the parsed block4. Target collections are mutually exclusive;
        // inner dependees of outer-loop cases remain empty. Each method must
        // therefore produce exactly32 NEW checks, not pre-existing inner work.
        auto &block=get<spirv_cross::SPIRBlock>(4);
        for(unsigned i=0;i<32;i++) {
            uint32_t id=32+i;
            if(kind==0)variable.dependees.push_back(id);
            else if(kind==1)expression.buffer_pointer_dependees.push_back(id);
            else if(kind==5)block.invalidate_expressions.push_back(id);
            else if(kind==4 || kind==9) {
                auto &pointer=set<spirv_cross::SPIRExpression>(id,"original",10,false);pointer.buffer_pointer=true;
                buffer_pointer_variables.push_back(id);
            } else {
                set<spirv_cross::SPIRVariable>(id,10,spv::StorageClassPrivate);
                if(kind==2)aliased_variables.push_back(id);
                else if(kind==3 || kind==8)global_variables.push_back(id);
                else if(kind==6)function.local_variables.push_back(id);
                else {spirv_cross::SPIRFunction::Parameter parameter={};parameter.type=10;parameter.id=id;function.arguments.push_back(parameter);}
            }
        }
    }
    ~FlushCompiler() {check_after(std::uncaught_exception());}
    void invoke() {
        switch(kind) {
        case 0:flush_dependees(get<spirv_cross::SPIRVariable>(13));break;
        case 1:flush_dependees(get<spirv_cross::SPIRExpression>(12));break;
        case 2:flush_all_aliased_variables();break;
        case 3:case 4:flush_all_atomic_capable_variables();break;
        case 5:flush_control_dependent_expressions(4);break;
        default:flush_all_active_variables();break;
        }
    }
    void check_after(bool interrupted) {
        size_t expected=interrupted?7:32;
        if(kind==0 || kind==1 || kind==5) {
            assert(invalid_expressions.size()==expected);
            for(unsigned i=0;i<expected;i++)assert(invalid_expressions.count(32+i)==1);
            size_t remaining=kind==0?get<spirv_cross::SPIRVariable>(13).dependees.size():
                kind==1?get<spirv_cross::SPIRExpression>(12).buffer_pointer_dependees.size():
                get<spirv_cross::SPIRBlock>(4).invalidate_expressions.size();
            assert(remaining==(interrupted?32:0)); // trailing clear remains after the full loop.
        } else assert(invalid_expressions.empty());
    }
};
struct Stop {unsigned calls;int status;};
static int checkpoint(void *context,uint64_t work,uint64_t nodes,uint64_t bytes) {
    Stop &state=*static_cast<Stop *>(context);assert(work==1 && nodes==0 && bytes==0);
    ++state.calls;return state.status && state.calls==8?state.status:0;
}
static void run(unsigned kind,int status) {
    // Budget scope begins only after the original IR fixture exists, isolating
    // checks added by this patch from parser/pool construction checkpoints.
    Stop state{0,status};bool interrupted=false;
    try {
        FlushCompiler compiler(kind);
        canopy_cross_budget::scope budget(checkpoint,&state);
        compiler.invoke();
        // On either normal return or exception the derived destructor checks
        // expected IR/clear state, then real base destruction owns the unwind.
    } catch(const canopy_cross_budget::failure &failure) {
        assert(failure.status==status);interrupted=true;
    }
    assert(interrupted==(status!=0));assert(state.calls==(status?8:32));
}
int main(int argc,char **argv) {
    assert(argc==3);unsigned kind=unsigned(std::atoi(argv[1]));int status=std::atoi(argv[2]);
    assert(kind<10 && (status==5 || status==6));run(kind,status);
    run(kind,0); // independent fresh request after the failed scope/unwind.
    std::cout<<"{\"status\":0}\n";
}
