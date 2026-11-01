#include "JustAnEQRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
// Apple arm64's int atomics must be lock-free; fail compilation otherwise.
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "RT controls require lock-free int atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "RT timestamps require lock-free atomics");
struct EQControl {
    atomic_ullong started_at;
    atomic_uint stop;
    atomic_uint silent;
    atomic_uint fault;
    atomic_uint parameters[17]; // balance, boost dB, ten graphic dB, four mixer dB, mode
};
EQControl *eq_control_create(void) {
    EQControl *c = malloc(sizeof(*c));
    if (!c) return NULL;
    atomic_init(&c->stop, 0);
    atomic_init(&c->started_at, 0);
    atomic_init(&c->silent, 0);
    atomic_init(&c->fault, 0);
    for (int i = 0; i < 17; ++i) atomic_init(&c->parameters[i], 0);
    return c;
}
void eq_control_destroy(EQControl *c) { free(c); }
void eq_set_started_at(EQControl *c, uint64_t time) { atomic_store_explicit(&c->started_at, time, memory_order_release); }
uint64_t eq_started_at(EQControl *c) { return atomic_load_explicit(&c->started_at, memory_order_acquire); }
void eq_request_stop(EQControl *c) { atomic_store_explicit(&c->stop, 1, memory_order_release); }
bool eq_stop_requested(EQControl *c) { return atomic_load_explicit(&c->stop, memory_order_acquire) != 0; }
void eq_mark_fault(EQControl *c) { atomic_store_explicit(&c->fault, 1, memory_order_release); }
bool eq_has_fault(EQControl *c) { return atomic_load_explicit(&c->fault, memory_order_acquire) != 0; }
void eq_mark_silent(EQControl *c) { atomic_store_explicit(&c->silent, 1, memory_order_release); }
bool eq_is_silent(EQControl *c) { return atomic_load_explicit(&c->silent, memory_order_acquire) != 0; }
void eq_set_parameter(EQControl *c, int index, float value) {
    if (index < 0 || index >= 17) return;
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    atomic_store_explicit(&c->parameters[index], bits, memory_order_relaxed);
}
float eq_get_parameter(EQControl *c, int index) {
    if (index < 0 || index >= 17) return 0;
    uint32_t bits = atomic_load_explicit(&c->parameters[index], memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}
