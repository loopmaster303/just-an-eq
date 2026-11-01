#ifndef JUST_AN_EQ_RT_H
#define JUST_AN_EQ_RT_H
#include <stdbool.h>
#include <stdint.h>
typedef struct EQControl EQControl;
EQControl *eq_control_create(void);
void eq_control_destroy(EQControl *control);
void eq_set_started_at(EQControl *control, uint64_t nanoseconds);
uint64_t eq_started_at(EQControl *control);
void eq_request_stop(EQControl *control);
bool eq_stop_requested(EQControl *control);
void eq_mark_fault(EQControl *control);
bool eq_has_fault(EQControl *control);
void eq_mark_silent(EQControl *control);
bool eq_is_silent(EQControl *control);
void eq_set_parameter(EQControl *control, int index, float value);
float eq_get_parameter(EQControl *control, int index);
#endif
