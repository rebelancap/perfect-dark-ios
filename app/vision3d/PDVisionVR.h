// PDVisionVR.h — the VR mode's seam (docs/VR-CHARTER.md, round R0).
//
// VR is a THIRD mode beside the flat window and the 3D panel (charter D1): its
// own ImmersiveSpace ("PDVR", with a live {.mixed, .full} immersion-style set),
// its own compositor loop (PDVRImmersive.m), and an eye law the engine
// substitutes for the game's projection at 0030's two MP sites (overlay 0057,
// D-100). Everything here is visionOS-only, like PDVision3D.h. The iPhone
// target compiles none of it and the engine references none of it off
// visionOS (PD_VISION_STEREO is 0 there), so no iPhone shims are needed.
//
// R0 is the spike + the harness: a FROZEN head pose (identity, or the bridge's
// injected one), the sim's synthetic second eye at +/-31.5 mm, the compositor's
// contract and depth convention measured, and the `vr` dump family on :8785.
#pragma once

#include <TargetConditionals.h>

#ifndef TARGET_OS_VISION
#define TARGET_OS_VISION 0
#endif

#if TARGET_OS_VISION

#import <Foundation/Foundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Engine-facing (overlay 0057, gfx_pc.cpp). Engine thread.
// ---------------------------------------------------------------------------

/** 1 while the VR eye law replaces the 3D fold: VR loop live, world mode, a
 *  pose latched. 0 in 2D and in the 3D panel mode. */
int pdVisionVRActive(void);

/**
 * The latched law for `eye`: E = game view space -> eye space (PD units,
 * ROW-vector, so clip = v * E * P), the compositor's frustum tangents
 * (left, right, bottom, top) and the `vr set near|far` override (0 = the
 * game's own depth). Returns the latch generation, 0 if nothing is latched.
 */
unsigned int pdVisionVREye(int eye, float E[4][4], float tan[4], float depth[2]);

/** The depth row of the last plain WORLD projection (for the shell's EyeVP). */
void pdVisionVRNoteWorldDepth(float p22, float p32);

/** What the engine actually substituted for a plain WORLD load, per eye. */
void pdVisionVRNoteEyeMP(int eye, int cls, const float m[4][4]);

/** Engine thread, from pdVisionEyeBeginPair: latch one pose for both eyes. */
void pdVisionVRLatch(void);

// ---------------------------------------------------------------------------
// Shell-facing
// ---------------------------------------------------------------------------

/** 1 when the next immersive open is a VR space (set by `vr on`). */
int pdVisionVRWanted(void);
/** Which VR space: 0 = PDVR, 1 = PDVRTestA (.mixed), 2 = PDVRTestB (.full). */
int pdVisionVRSpaceIndex(void);
/** 1 while the PDVR space's live style is .full. */
int pdVisionVRStyleFull(void);
/** The 3D/VR exit has finalized (PDHostViewController): VR is no longer wanted. */
void pdVisionVRNoteExited(void);

/** The eye aspect VR wants ((tR-tL)/(tT-tB)), 0 when VR is not sizing the eye. */
float pdVisionVREyeAspect(void);
/** PDEyeTargets.mm: re-wrap the ring at the next frame boundary (VR's aspect moved). */
void pdVisionEyeVRResize(void);

/** The VR compositor loop. Own thread, spawned by PDVisionApp.swift. */
void pdVisionVRImmersiveRun(void *lr);

/** The bridge's `vr ...` family (compiled out of public builds). */
NSString *pdVisionVRCommand(NSArray<NSString *> *args);

// Implemented in Swift (@_cdecl): the PDVR space's live immersion style.
void PD_VRPushStyle(int full);

#ifdef __cplusplus
}
#endif

#endif // TARGET_OS_VISION
