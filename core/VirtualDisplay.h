// Private CGVirtualDisplay (same path as ~/kindle-screen/vd/kindle_vd.m): gives a lid-closed Mac a desktop to capture.
#include <stdint.h>
/// Creates a HiDPI virtual display of w x h points (2x backing). Returns its display id, 0 on failure.
uint32_t tinytv_vd_create(unsigned int w, unsigned int h);
/// Removes it again.
void tinytv_vd_destroy(void);
