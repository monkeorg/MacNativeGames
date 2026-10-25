// Original internal dependency graphs through actual protected Cross handlers.
// These are source-level resource/unwind fixtures, not SPIR-V parser reachability
// or arbitrary shader/runtime acceptance. No graph/visited behavior is replaced.
#include "canopy_cross_budget.hpp"
#include "spirv_msl.hpp"
#include <cassert>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using Graph=std::unordered_map<uint32_t,std::unordered_set<uint32_t>>;
struct Poll {unsigned calls=0;int status=0;};
static int checkpoint(void *context,uint64_t work,uint64_t nodes,uint64_t bytes) {
    Poll &poll=*static_cast<Poll *>(context);assert(work==1 && nodes==0 && bytes==0);
    ++poll.calls;return poll.status && poll.calls==8?poll.status:0;
}
static Graph graph(unsigned shape) {
    Graph result;
    if(shape==0)result[32].insert(32); // Cycle: visited-set behavior stays original.
    else if(shape==1)for(uint32_t i=32;i<544;i++)result[i].insert(i+1); // Deep acyclic chain.
    else {assert(shape==2);for(uint32_t i=33;i<=96;i++)result[32].insert(i);} // Wide, shallow.
    return result;
}
class DependencyCompiler : public spirv_cross::CompilerMSL {
    bool *unwound;
public:
    explicit DependencyCompiler(bool *destroyed) : CompilerMSL(std::vector<uint32_t>{
        0x07230203,0x10000,0,5,0,0x20011,1,0x3000e,0,1,
        0x5000f,5,3,0x6e69616d,0,0x60010,3,17,1,1,1,
        0x20013,1,0x30021,2,1,0x50036,1,3,0,2,0x200f8,4,0x100fd,0x10038}),unwound(destroyed) {
        ir.set_id_bounds(1024);
    }
    ~DependencyCompiler() {if(std::uncaught_exception())*unwound=true;}
    void invoke(unsigned kind,unsigned shape,Poll &poll) {
        assert(kind<2);
        if(kind==0) {
            AnalyzeVariableScopeAccessHandler handler(*this,get<spirv_cross::SPIRFunction>(3));
            handler.rvalue_forward_children=graph(shape);
            // Construct real handler/maps before the budget starts. Actual
            // handler then compiler destruction participate in exception unwind.
            canopy_cross_budget::scope budget(checkpoint,&poll);
            handler.notify_variable_access(32,4);
            assert(shape==2 && handler.accessed_variables_to_block.empty());
            assert(handler.accessed_temporaries_to_block.size()==65);
            for(uint32_t i=32;i<=96;i++)assert(handler.accessed_temporaries_to_block.at(i).count(4)==1);
        } else {
            // The borrowed set outlives its actual handler; entry/IR references
            // remain compiler-owned until after that handler has been destroyed.
            const std::unordered_set<uint32_t> dref;
            CombinedImageSamplerUsageHandler handler(*this,dref);
            handler.dependency_hierarchy=graph(shape);
            canopy_cross_budget::scope budget(checkpoint,&poll);
            handler.add_hierarchy_to_comparison_ids(32);
            assert(shape==2 && handler.comparison_ids.size()==65);
            for(uint32_t i=32;i<=96;i++)assert(handler.comparison_ids.count(i)==1);
        }
    }
};
static void run(unsigned kind,unsigned shape,int status) {
    Poll poll;poll.status=status;bool stopped=false,unwound=false;
    try {DependencyCompiler compiler(&unwound);compiler.invoke(kind,shape,poll);}
    catch(const canopy_cross_budget::failure &failure) {
        assert(failure.status==(status?status:5));stopped=true;
    }
    if(shape<2) {
        assert(!status && stopped && unwound);
        // Each edge and each attempted frame is charged. The built-in256 depth
        // ceiling rejects frame257 before recursion can exhaust the native stack.
        assert(poll.calls==513);
    } else if(status)assert(stopped && unwound && poll.calls==8);
    else assert(!stopped && !unwound && poll.calls==129); // root+64edges+64leaf frames.
}
int main(int argc,char **argv) {
    assert(argc==4);unsigned kind=unsigned(std::atoi(argv[1])),shape=unsigned(std::atoi(argv[2]));int status=std::atoi(argv[3]);
    assert(kind<2 && shape<3 && ((shape<2 && status==0)||(shape==2 && (status==5 || status==6))));
    run(kind,shape,status);run(kind,2,0); // Entirely fresh handler/compiler/scope after failure.
    std::cout<<"{\"status\":0}\n";
}
