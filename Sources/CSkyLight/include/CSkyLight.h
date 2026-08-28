// Private SkyLight / CoreGraphics window-server declarations.
//
// Every symbol here was verified to exist in the SkyLight and CoreGraphics
// export tables on the target OS (see Tools/check-symbols.sh). Signatures come
// from the JankyBorders / yabai reverse-engineering lineage plus empirical
// probing; where a signature is unverified it is marked UNVERIFIED and must be
// exercised through Probe.swift before being relied on.

#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdint.h>

typedef int CGSConnectionID;
typedef uint32_t CGSWindowID;
typedef uint32_t CGSSpaceID;
typedef uint32_t CAContextID;
typedef CFTypeRef CGSRegionRef;
typedef CFTypeRef SLSTransactionRef;
typedef CFTypeRef SLSWindowQueryRef;
typedef CFTypeRef SLSWindowIteratorRef;

// ---------------------------------------------------------------- connection

extern CGSConnectionID SLSMainConnectionID(void);
extern CGError SLSNewConnection(int zero, CGSConnectionID *cid);
extern CGError SLSReleaseConnection(CGSConnectionID cid);
extern CGError SLSGetConnectionPSN(CGSConnectionID cid, ProcessSerialNumber *psn);
extern CGError SLSConnectionGetPID(CGSConnectionID cid, pid_t *pid);
extern CGError SLSGetWindowOwner(CGSConnectionID cid, CGSWindowID wid, CGSConnectionID *out_cid);
extern OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError SLSGetConnectionIDForPSN(CGSConnectionID cid, ProcessSerialNumber *psn, CGSConnectionID *out_cid);

// -------------------------------------------------------------------- region

extern CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *out_region);
extern CGSRegionRef CGRegionCreateEmptyRegion(void);
extern CGError CGSNewRegionWithRectList(const CGRect *rects, int count, CGSRegionRef *out_region);

// -------------------------------------------------------------------- window

extern CGError SLSNewWindow(CGSConnectionID cid, int type, float x, float y,
                            CGSRegionRef region, CGSWindowID *out_wid);
extern CGError SLSNewWindowWithOpaqueShapeAndContext(CGSConnectionID cid, int type,
                                                     CGSRegionRef region,
                                                     CGSRegionRef opaque_shape,
                                                     int options, uint64_t *tags,
                                                     float x, float y, int tag_size,
                                                     CGSWindowID *out_wid, void *context);
extern CGError SLSReleaseWindow(CGSConnectionID cid, CGSWindowID wid);

extern CGError SLSSetWindowShape(CGSConnectionID cid, CGSWindowID wid,
                                 float x_offset, float y_offset, CGSRegionRef shape);
extern CGError SLSSetWindowOpaqueShape(CGSConnectionID cid, CGSWindowID wid, CGSRegionRef shape);
extern CGError SLSSetWindowEventShape(CGSConnectionID cid, CGSWindowID wid, CGSRegionRef shape);
extern CGError SLSSetWindowBackingStoreOverrideResolution(CGSConnectionID cid, CGSWindowID wid, double res);
extern CGError SLSSetWindowBackingStorePixelDimensionsHint(CGSConnectionID cid, CGSWindowID wid, int width, int height);
extern CGError SLSSetWindowToReleaseBackingOnOrderOut(CGSConnectionID cid, CGSWindowID wid, bool release);
extern CGError SLSSetWindowResolution(CGSConnectionID cid, CGSWindowID wid, double res);
extern CGError SLSSetWindowOpacity(CGSConnectionID cid, CGSWindowID wid, bool opaque);
extern CGError SLSSetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float alpha);
extern CGError SLSSetWindowLevel(CGSConnectionID cid, CGSWindowID wid, int level);
extern CGError SLSSetWindowSubLevel(CGSConnectionID cid, CGSWindowID wid, int sub_level);
extern CGError SLSSetWindowTags(CGSConnectionID cid, CGSWindowID wid, uint64_t *tags, int tag_size);
extern CGError SLSClearWindowTags(CGSConnectionID cid, CGSWindowID wid, uint64_t *tags, int tag_size);
extern CGError SLSSetWindowTransform(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform transform);
extern CGError SLSWindowSetShadowProperties(CGSWindowID wid, CFDictionaryRef properties);
extern CGError SLSSetWindowBackgroundBlurRadius(CGSConnectionID cid, CGSWindowID wid, uint32_t radius);

extern CGError SLSOrderWindow(CGSConnectionID cid, CGSWindowID wid, int order, CGSWindowID rel_wid);
extern CGError SLSMoveWindow(CGSConnectionID cid, CGSWindowID wid, const CGPoint *origin);

extern CGError SLSGetWindowBounds(CGSConnectionID cid, CGSWindowID wid, CGRect *out_frame);
extern CGError SLSWindowIsOrderedIn(CGSConnectionID cid, CGSWindowID wid, bool *out_shown);
extern CGError SLSGetWindowLevel(CGSConnectionID cid, CGSWindowID wid, int64_t *out_level);
extern int32_t SLSGetWindowSubLevel(CGSConnectionID cid, CGSWindowID wid);

// Window grouping. UNVERIFIED signatures - probe before use. If these work
// across connections they let the window server translate the border together
// with its target, removing move latency entirely.
extern CGError SLSSetWindowMovementGroup(CGSConnectionID cid, CGSWindowID wid, CGSWindowID group_wid);
extern CGError SLSSetWindowOriginRelativeToWindow(CGSConnectionID cid, CGSWindowID wid,
                                                  CGSWindowID rel_wid, float x, float y);
extern CGError SLSSetWindowShadowGroup(CGSConnectionID cid, CGSWindowID wid, CGSWindowID group_wid);
extern CGError SLSSetWindowParent(CGSConnectionID cid, CGSWindowID wid, CGSWindowID parent_wid);

// --------------------------------------------------------- CoreAnimation bind

// Binds a remote CAContext's layer tree to a window-server window, so the
// window is composited from the layer tree instead of a CPU backing store.
// UNVERIFIED signature - probe before use.
extern CGError SLSSetWindowLayerContext(CGSConnectionID cid, CGSWindowID wid, CAContextID context_id);
extern CGError SLSGetWindowLayerContext(CGSConnectionID cid, CGSWindowID wid, CAContextID *out_context_id);

// Surface-based alternative to the above.
extern CGError SLSAddSurface(CGSConnectionID cid, CGSWindowID wid, uint32_t *out_sid);
extern CGError SLSRemoveSurface(CGSConnectionID cid, CGSWindowID wid, uint32_t sid);
extern CGError SLSSetSurfaceBounds(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, CGRect bounds);
extern CGError SLSSetSurfaceResolution(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, double res);
extern CGError SLSOrderSurface(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, int order, uint32_t rel_sid);
// Verified empirically on macOS 26: the fourth argument is the CAContext id.
// Passing 0 there unbinds, which is why a 6-argument (cid,wid,sid,0,0,ctx)
// call appears to succeed while leaving the surface bound to nothing.
extern CGError SLSBindSurface(CGSConnectionID cid, CGSWindowID wid, uint32_t sid,
                              CAContextID context_id);
extern CGError SLSGetSurfaceCount(CGSConnectionID cid, CGSWindowID wid, int *out_count);
extern CGError SLSGetSurfaceList(CGSConnectionID cid, CGSWindowID wid, int max, uint32_t *out_list, int *out_count);
extern CGError SLSGetSurfaceBounds(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, CGRect *out_bounds);
extern CGError SLSGetSurfaceFrontBufferID(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, uint32_t *out_buffer_id);
extern CGError SLSGetWindowTags(CGSConnectionID cid, CGSWindowID wid, uint64_t *tags, int tag_size);
extern CGError SLSGetWindowOpacity(CGSConnectionID cid, CGSWindowID wid, bool *out_opaque);
extern CGError SLSGetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float *out_alpha);
extern CGError SLSGetSurfaceBinding(CGSConnectionID cid, CGSWindowID wid, uint32_t sid, CAContextID *out_context_id);
extern CGError SLSSetWindowOriginRelativeToWindowWithPoint(CGSConnectionID cid, CGSWindowID wid, CGSWindowID rel_wid, CGPoint origin);

extern CGContextRef SLWindowContextCreate(CGSConnectionID cid, CGSWindowID wid, CFDictionaryRef options);
extern CGError SLSFlushWindowContentRegion(CGSConnectionID cid, CGSWindowID wid, void *dirty);

// --------------------------------------------------------------- transaction

extern SLSTransactionRef SLSTransactionCreate(CGSConnectionID cid);
extern CGError SLSTransactionCommit(SLSTransactionRef t, int synchronous);
extern CGError SLSTransactionOrderWindow(SLSTransactionRef t, CGSWindowID wid, int order, CGSWindowID rel_wid);
extern CGError SLSTransactionMoveWindowWithGroup(SLSTransactionRef t, CGSWindowID wid, CGPoint origin);
extern CGError SLSTransactionSetWindowShape(SLSTransactionRef t, CGSWindowID wid,
                                            float x_offset, float y_offset, CGSRegionRef shape);
extern CGError SLSTransactionSetWindowLevel(SLSTransactionRef t, CGSWindowID wid, int level);
extern CGError SLSTransactionSetWindowSubLevel(SLSTransactionRef t, CGSWindowID wid, int sub_level);
extern CGError SLSTransactionSetWindowAlpha(SLSTransactionRef t, CGSWindowID wid, float alpha);
extern CGError SLSTransactionSetWindowTransform(SLSTransactionRef t, CGSWindowID wid,
                                                int unused_a, int unused_b, CGAffineTransform transform);
extern CGError SLSTransactionSetWindowSystemAlpha(SLSTransactionRef t, CGSWindowID wid, float alpha);

extern CGError SLSWindowFreezeWithOptions(CGSConnectionID cid, CGSWindowID wid, CFTypeRef options);
extern CGError SLSWindowThaw(CGSConnectionID cid, CGSWindowID wid);
extern CGError SLSDisableUpdate(CGSConnectionID cid);
extern CGError SLSReenableUpdate(CGSConnectionID cid);

// ---------------------------------------------------------------- space/query

extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int selector, CFArrayRef window_list);
extern CGError SLSMoveWindowsToManagedSpace(CGSConnectionID cid, CFArrayRef window_list, uint64_t sid);
extern CFArrayRef SLSCopyManagedDisplays(CGSConnectionID cid);
extern CFArrayRef SLSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern CFStringRef SLSCopyManagedDisplayForWindow(CGSConnectionID cid, CGSWindowID wid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(CGSConnectionID cid, CFStringRef uuid);
extern CFStringRef SLSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID cid);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(CGSConnectionID cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);

extern SLSWindowQueryRef SLSWindowQueryWindows(CGSConnectionID cid, CFArrayRef windows, uint32_t options);
extern SLSWindowIteratorRef SLSWindowQueryResultCopyWindows(SLSWindowQueryRef query);
extern int SLSWindowIteratorGetCount(SLSWindowIteratorRef it);
extern bool SLSWindowIteratorAdvance(SLSWindowIteratorRef it);
extern CGSWindowID SLSWindowIteratorGetWindowID(SLSWindowIteratorRef it);
extern CGSWindowID SLSWindowIteratorGetParentID(SLSWindowIteratorRef it);
extern uint64_t SLSWindowIteratorGetTags(SLSWindowIteratorRef it);
extern uint64_t SLSWindowIteratorGetAttributes(SLSWindowIteratorRef it);
extern int SLSWindowIteratorGetLevel(SLSWindowIteratorRef it);
extern CGRect SLSWindowIteratorGetBounds(SLSWindowIteratorRef it);
extern pid_t SLSWindowIteratorGetPID(SLSWindowIteratorRef it);
extern float SLSWindowIteratorGetAlpha(SLSWindowIteratorRef it);

// ------------------------------------------------------------------- events

extern CGError SLSRegisterNotifyProc(void *handler, uint32_t event, void *context);
extern CGError SLSRegisterConnectionNotifyProc(CGSConnectionID cid, void *handler, uint32_t event, void *context);
extern CGError SLSRequestNotificationsForWindows(CGSConnectionID cid, uint32_t *window_list, int window_count);
extern CGError SLSGetEventPort(CGSConnectionID cid, mach_port_t *out_port);
// Returns +1: make the ownership explicit so Swift releases each drained
// event rather than leaking one per notification.
extern CGEventRef SLEventCreateNextEvent(CGSConnectionID cid) CF_RETURNS_RETAINED;
extern void _CFMachPortSetOptions(CFMachPortRef port, int options);

#endif // CSKYLIGHT_H
