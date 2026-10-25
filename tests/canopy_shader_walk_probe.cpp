// Original malformed internal graphs over actual protected Cross traversal APIs.
// No game shader bytes and no substitute compiler. Without the loop checkpoint
// these cycles never return; the parent test imposes a process timeout.
#include "canopy_cross_budget.hpp"
#include "spirv_msl.hpp"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <vector>

class WalkCompiler : public spirv_cross::CompilerMSL {
public:
    WalkCompiler() : CompilerMSL(std::vector<uint32_t>{
        0x07230203,0x10000,0,5,0,0x20011,1,0x3000e,0,1,
        0x5000f,5,3,0x6e69616d,0,0x60010,3,17,1,1,1,
        0x20013,1,0x30021,2,1,0x50036,1,3,0,2,0x200f8,4,0x100fd,0x10038}) {
        ir.set_id_bounds(16);
        auto &array=set<spirv_cross::SPIRType>(9,spv::OpTypeArray);array.parent_type=9;
        auto &base=set<spirv_cross::SPIRType>(10,spv::OpTypeInt);base.basetype=spirv_cross::SPIRType::UInt;
        auto &expression=set<spirv_cross::SPIRExpression>(11,"original",10,false);expression.loaded_from=11;
    }
    void walk_array(){(void)type_is_array_of_pointers(get<spirv_cross::SPIRType>(9));}
    void walk_expression(){(void)maybe_get_backing_buffer_pointer(11);}
    void repair() {
        get<spirv_cross::SPIRType>(9).parent_type=10;
        auto &expression=get<spirv_cross::SPIRExpression>(11);expression.loaded_from=0;expression.buffer_pointer=true;
    }
};
struct stop {unsigned calls;int status;};
static int checkpoint(void *context,uint64_t work,uint64_t nodes,uint64_t bytes) {
    stop *state=static_cast<stop *>(context);assert(work==1 && nodes==0 && bytes==0);
    return ++state->calls==8?state->status:0;
}
int main(int argc,char **argv) {
    assert(argc==3);int type=std::atoi(argv[1]),status=std::atoi(argv[2]);assert(type<=1 && (status==5 || status==6));
    WalkCompiler compiler;stop state{0,status};bool stopped=false;
    {
        canopy_cross_budget::scope budget(checkpoint,&state);
        try{if(type)compiler.walk_expression();else compiler.walk_array();}
        catch(const canopy_cross_budget::failure &failure){assert(failure.status==status);stopped=true;}
    }
    assert(stopped && state.calls==8);compiler.repair();
    {
        canopy_cross_budget::scope budget(nullptr,nullptr);compiler.walk_array();compiler.walk_expression();
    }
    std::cout<<"{\"status\":0}\n";
}
