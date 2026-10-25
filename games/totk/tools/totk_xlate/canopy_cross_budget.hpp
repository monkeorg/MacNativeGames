#ifndef CANOPY_CROSS_BUDGET_HPP
#define CANOPY_CROSS_BUDGET_HPP
#include "inprocess_cross.h"
#include <chrono>
#include <cstdint>
namespace canopy_cross_budget {
struct failure { int status; };
class scope {
    scope *previous;
    canopy_budget_checkpoint callback;
    void *context;
    std::chrono::steady_clock::time_point start;
    uint64_t work=0,nodes=0,tracked=0;
    unsigned depth=0;
public:
    scope(canopy_budget_checkpoint,void *);
    ~scope() noexcept;
    void check(uint64_t,uint64_t,uint64_t);
    void enter();
    void leave() noexcept;
};
void step(uint64_t work=1,uint64_t nodes=0,uint64_t bytes=0);
struct depth_scope { depth_scope();~depth_scope() noexcept; };
}
#endif
