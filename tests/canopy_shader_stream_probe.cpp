// Original heap-growth fixture using the actual privately patched Cross class.
#include "canopy_cross_budget.hpp"
#include "spirv_cross_containers.hpp"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <string>
struct stop {int status;unsigned hits;};
static int checkpoint(void *context,uint64_t,uint64_t,uint64_t bytes) {
    stop *state=static_cast<stop *>(context);
    // Stack8 -> heap16 (8 bytes used), then append32 fills8 and grows24.
    // Stop at that SECOND allocation checkpoint while a heap pointer is owned.
    if(bytes==24){state->hits++;return state->status;}return 0;
}
int main(int argc,char **argv) {
    assert(argc==2);int status=std::atoi(argv[1]);assert(status==0 || status==5 || status==6);
    stop state{status,0};bool stopped=false;
    {
        canopy_cross_budget::scope budget(checkpoint,&state);
        try {
            spirv_cross::StringStream<8,16> stream;
            stream<<std::string(16,'a');stream<<std::string(32,'b');
            assert(stream.str()==std::string(16,'a')+std::string(32,'b'));
        } catch(const canopy_cross_budget::failure &failure) {assert(failure.status==status);stopped=true;}
    }
    assert(state.hits==1 && stopped==(status!=0));
    // A failed operation must unwind safely and not poison subsequent scopes.
    {
        canopy_cross_budget::scope budget(nullptr,nullptr);
        spirv_cross::StringStream<8,16> stream;stream<<std::string(64,'c');assert(stream.str()==std::string(64,'c'));stream.reset();
    }
    std::cout<<"{\"status\":0}\n";
}
