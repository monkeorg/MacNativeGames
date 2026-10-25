#include "canopy_cross_budget.hpp"
namespace canopy_cross_budget {
static thread_local scope *current=nullptr;
scope::scope(canopy_budget_checkpoint check,void *opaque)
    : previous(current),callback(check),context(opaque),start(std::chrono::steady_clock::now()) {current=this;}
scope::~scope() noexcept {current=previous;}
void scope::check(uint64_t units,uint64_t added,uint64_t bytes) {
    const uint64_t max_work=64ull*1024*1024,max_nodes=262144,max_tracked=256ull*1024*1024;
    if(units>max_work-work || added>max_nodes-nodes || bytes>max_tracked-tracked)throw failure{5};
    work+=units;nodes+=added;tracked+=bytes;
    if(callback) {
        int status=callback(context,units,added,bytes);
        if(status)throw failure{status==6?6:status==5?5:3};
    }
    if(std::chrono::steady_clock::now()-start>=std::chrono::seconds(5))throw failure{5};
}
void scope::enter(){check(1,0,0);if(++depth>256)throw failure{5};}
void scope::leave() noexcept {if(depth)depth--;}
void step(uint64_t work,uint64_t nodes,uint64_t bytes){if(current)current->check(work,nodes,bytes);}
depth_scope::depth_scope(){if(current)current->enter();}
depth_scope::~depth_scope() noexcept {if(current)current->leave();}
}
