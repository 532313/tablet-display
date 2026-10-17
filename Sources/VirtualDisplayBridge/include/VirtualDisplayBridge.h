#ifndef VIRTUAL_DISPLAY_BRIDGE_H
#define VIRTUAL_DISPLAY_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

// The returned handle must be released with VDDestroy.
// pixelWidth/Height is the backing resolution; logicalWidth/Height is the UI
// point size. A 2:1 ratio creates a HiDPI display.
void *VDCreate(uint32_t pixelWidth, uint32_t pixelHeight,
               uint32_t logicalWidth, uint32_t logicalHeight,
               uint32_t *displayID);
bool VDSetNativeMode(uint32_t displayID, uint32_t width, uint32_t height);
bool VDPlaceRightOfMain(uint32_t displayID);
void VDDestroy(void *handle);

#endif
