// PDVRImmersive.m — the VR mode's compositor loop, eye math and diagnostics
// (docs/VR-CHARTER.md §4 D1/D2/D10, §5 R0; docs/VR-R0-FINDINGS.md).
//
// A SECOND loop beside PDImmersive.m's panel loop, run by the sibling
// ImmersiveSpaces PDVisionApp.swift declares for VR ("PDVR", "PDVRTestA",
// "PDVRTestB"). The "PD-3D" space and its loop are not touched (charter D1).
// The loop SHAPE is PDImmersive.m's, line for line where it matters, because
// every line of that sequence wedged an engine somewhere in the family: frame
// pacing AND a per-frame device anchor; depth cleared and stored; the queue
// from the drawable's device; a NULL drawable is `continue` WITHOUT
// end_submission; the projection from cp_drawable_compute_projection (never
// cp_view_get_tangents, which traps under mixed immersion); a pool per frame.
// It shares the 3D mode's lifecycle globals (pdVision3dImmStop/Running/Frames/
// Hz), so the host's exit sequencing, `3d state` and the Crown reconcile all
// work for either loop with nothing changed.
//
// TWO VARIANTS (charter R0 a/b), switched by `vr world on|off`:
//   world=0  clear each view to a half-transparent colour and present — the
//            pure space/present contract test, no engine involved;
//   world=1  blit each engine eye across its whole drawable slice. The engine
//            rendered it with the eye law this file composes and publishes
//            (overlay 0057 substitutes it at 0030's two MP sites).
//
// THE EYE LAW (charter D2), conventions stated because a wrong one is silent:
//   * ARKit/CompositorServices space and PD's view space are BOTH right-handed,
//     Y-up, -Z forward. No axis flip anywhere; the only conversion is the scalar
//     world scale in PD units per metre (85, the donor's constant; `vr set`).
//   * A: the game camera sits at the VR anchor; `height` raises the eye.
//   * V: inverse of the eye's pose relative to the anchor: head (R0: FROZEN
//     identity, or the bridge's injected pose) x cp_view_get_transform, with
//     the simulator's missing second view synthesized at +/-31.5 mm.
//   * P: the compositor's asymmetric frustum TANGENTS, recovered exactly from
//     cp_drawable_compute_projection (tR = (c2x+1)/c0x, tL = (c2x-1)/c0x, same
//     for y), with a FORWARD depth row in game units: the engine keeps each
//     class's own depth (0057), and the compositor's own matrix is measured
//     (`vr contract`) rather than handed to a forward-Z engine.
//   * Published ROW-vector (Fast3D's order): F[i][j] = M.columns[i][j], which
//     is simd's own memory layout, so a memcpy is the transpose.
#import "PDVision3D.h"
#import "PDVisionVR.h"

#if TARGET_OS_VISION

#import "PDPacing.h"
#import "PDShell.h"

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include <math.h>
#include <string.h>
#include <unistd.h>
#include <os/lock.h>
#include <stdatomic.h>

// The head of PD's g_Vars (src/include/types.h, ROM-layout offsets 0x000-0x00c),
// read-only, for `vr pace`'s tick rates. Declared by layout rather than by
// dragging the decomp's headers into an ObjC file; the four fields are the
// documented N64 layout and the struct's first members.
extern struct {
	int32_t diffframe60;
	float diffframe60f;
	int32_t lvframe60;
	int32_t lvframenum;
} g_Vars;

// The engine's own readouts (PDShell.h declares them; repeated here for the two
// this file uses so it does not depend on that header's include order).
extern int menuIosDialogIsOpen(void);
extern int mainGetStageNum(void);
extern float videoGetAverageFPS(void);

// ---------------------------------------------------------------------------
// Tunables (live on the bridge: `vr set ...`). Main/bridge thread writes,
// compositor thread reads once per frame.
// ---------------------------------------------------------------------------
static volatile float s_scale = 85.0f;   // PD units per metre (charter D2/Q-VR4)
static volatile float s_height = 0.0f;   // metres added to the eye
static volatile float s_near = 0.0f;     // PD units; 0 = the game's own depth
static volatile float s_far = 0.0f;
static volatile int s_world = 1;         // 1 = engine eyes, 0 = clear to colour
static volatile int s_variant = 0;       // 0 PDVR / 1 PDVRTestA / 2 PDVRTestB
static volatile int s_styleFull = 0;     // PDVR's live style
static volatile int s_wanted = 0;        // the next immersive open is VR

// Synthetic pose injection (charter D10). Wins over the frozen pose while armed.
static volatile int s_injOn = 0;
static float s_injPos[3];
static float s_injYawDeg, s_injPitchDeg;

static const float kHalfIpd = 0.0315f;   // metres; the D2 first-light check

// ---------------------------------------------------------------------------
// The published law (compositor thread) and the engine's latch (engine thread)
// ---------------------------------------------------------------------------
typedef struct {
	float E[2][4][4];
	float tan[2][4];
	float depth[2];
	unsigned int gen;
	int valid;
} PDVRLaw;
static PDVRLaw s_pub, s_lat;
static os_unfair_lock s_lawLock = OS_UNFAIR_LOCK_INIT;

static volatile int s_loopRunning = 0;
static volatile float s_eyeAspect = 0.0f;

// The engine's notes (engine thread writes, bridge reads).
static volatile float s_worldP22 = 0.0f, s_worldP32 = 0.0f;
static float s_engMP[2][4][4];
static volatile unsigned int s_engMPGen[2];
static volatile unsigned long long s_engMPNotes[2];

// ---------------------------------------------------------------------------
// The contract and the pose, for the dumps (compositor thread writes)
// ---------------------------------------------------------------------------
typedef struct {
	int valid;
	size_t views, textures, ratemaps;
	unsigned long colorFmt, depthFmt;
	int layout;                      // 0 dedicated / 1 layered (inferred)
	double vpW[2], vpH[2];
	size_t texIdx[2], slice[2];
	float tanL[2], tanR[2], tanB[2], tanT[2];
	float rawC2z[2], rawC3z[2];
	float depthNear[2], depthFar[2];
	int depthKind[2];                // 0 forward-Z / 1 reverse-Z finite / 2 reverse-Z infinite far
	float zndc1m[2], zndc1000m[2], zndc10m[2];
	float rangeFar, rangeNear;       // cp_drawable_get_depth_range (x = far, y = near)
	float blitDepth;                 // the constant depth R0 writes
} PDVRContract;
static PDVRContract s_contract;

static simd_float4x4 s_head;               // head relative to the anchor, as used
static simd_float4x4 s_eyeTrack[2];        // eye pose relative to the anchor (metres)
static simd_float4x4 s_originFromDevice;   // ARKit's, for the record
static float s_E[2][4][4];                 // the published E, per eye
static float s_eyeVP[2][4][4];             // E * P_eye (world depth), per eye
static float s_Pe00[2];
static int s_anchored, s_synthEye2, s_poseSrc;
static const char *s_reason = "idle";
static int s_vrFrames;
static uint64_t s_presents;
static double s_compGpuMs;
static _Atomic(unsigned long long) s_seq;

// Eye readback (the per-eye pixel proof).
static volatile int s_capReq, s_capDone;
static uint32_t s_capHash[2], s_capMean[2], s_capAlphaMean[2], s_capAlphaMin[2];
static int s_capW[2], s_capH[2];

static unsigned long long pdvr_seq(void) { return atomic_fetch_add(&s_seq, 1) + 1; }

// ---------------------------------------------------------------------------
// Rolling 1 s pacing windows (charter D10 `vr pace`)
//
// Sampled by a 100 ms timer rather than inside a loop, so the numbers are
// honest in 2D, in the 3D panel loop and in the VR loop alike without adding a
// line to the shipped panel loop: both loops count pdVision3dImmFrames.
// ---------------------------------------------------------------------------
typedef struct {
	double t;
	unsigned long long frames;
	int32_t lvnum, lv60;
	int presents;
} PDVRSample;
#define PDVR_RING 32
static PDVRSample s_ring[PDVR_RING];
static int s_ringN, s_ringHead;
static os_unfair_lock s_paceLock = OS_UNFAIR_LOCK_INIT;
static dispatch_source_t s_paceTimer;

static void pdvr_pace_tick(void)
{
	PDVRSample x;
	x.t = CACurrentMediaTime();
	x.frames = PDShell.shared.frameCount;
	x.lvnum = g_Vars.lvframenum;
	x.lv60 = g_Vars.lvframe60;
	x.presents = pdVision3dImmFrames;
	os_unfair_lock_lock(&s_paceLock);
	s_ring[s_ringHead] = x;
	s_ringHead = (s_ringHead + 1) % PDVR_RING;
	if (s_ringN < PDVR_RING) s_ringN++;
	os_unfair_lock_unlock(&s_paceLock);
}

static void pdvr_pace_start(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		dispatch_queue_t q = dispatch_queue_create("com.rebelancap.perfectdark.vrpace",
			DISPATCH_QUEUE_SERIAL);
		s_paceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
		dispatch_source_set_timer(s_paceTimer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC,
			10 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(s_paceTimer, ^{ pdvr_pace_tick(); });
		dispatch_resume(s_paceTimer);
	});
}

/** Rates over the ~1 s window ending at the newest sample. 0 until 1 s exists. */
static void pdvr_pace_rates(double *fps, double *tps, double *sim60, double *hz, double *span)
{
	*fps = *tps = *sim60 = *hz = *span = 0.0;
	os_unfair_lock_lock(&s_paceLock);
	if (s_ringN >= 2) {
		const PDVRSample n = s_ring[(s_ringHead - 1 + PDVR_RING) % PDVR_RING];
		PDVRSample o = n;
		for (int i = 2; i <= s_ringN; i++) {
			const PDVRSample c = s_ring[(s_ringHead - i + PDVR_RING) % PDVR_RING];
			o = c;
			if (n.t - c.t >= 1.0) break;
		}
		const double dt = n.t - o.t;
		if (dt > 0.5) {
			*span = dt;
			*fps = (double)(n.frames - o.frames) / dt;
			*tps = (n.lvnum >= o.lvnum) ? (double)(n.lvnum - o.lvnum) / dt : 0.0;
			*sim60 = (n.lv60 >= o.lv60) ? (double)(n.lv60 - o.lv60) / dt : 0.0;
			*hz = (n.presents >= o.presents) ? (double)(n.presents - o.presents) / dt : 0.0;
		}
	}
	os_unfair_lock_unlock(&s_paceLock);
}

// ---------------------------------------------------------------------------
// Engine-facing (0057). Engine thread.
// ---------------------------------------------------------------------------

int pdVisionVRActive(void)
{
	return (s_loopRunning && s_world && s_lat.valid) ? 1 : 0;
}

unsigned int pdVisionVREye(int eye, float E[4][4], float tan[4], float depth[2])
{
	if (!s_lat.valid) {
		return 0;
	}
	const int e = (eye == PD_EYE_RIGHT) ? 1 : 0;
	memcpy(E, s_lat.E[e], sizeof(s_lat.E[e]));
	memcpy(tan, s_lat.tan[e], sizeof(s_lat.tan[e]));
	depth[0] = s_lat.depth[0];
	depth[1] = s_lat.depth[1];
	return s_lat.gen;
}

void pdVisionVRLatch(void)
{
	os_unfair_lock_lock(&s_lawLock);
	s_lat = s_pub;
	os_unfair_lock_unlock(&s_lawLock);
}

void pdVisionVRNoteWorldDepth(float p22, float p32)
{
	s_worldP22 = p22;
	s_worldP32 = p32;
}

void pdVisionVRNoteEyeMP(int eye, int cls, const float m[4][4])
{
	(void)cls;
	const int e = (eye == PD_EYE_RIGHT) ? 1 : 0;
	memcpy(s_engMP[e], m, sizeof(s_engMP[e]));
	s_engMPGen[e] = s_lat.gen;
	s_engMPNotes[e]++;
}

// ---------------------------------------------------------------------------
// Shell-facing
// ---------------------------------------------------------------------------

int pdVisionVRWanted(void) { return s_wanted; }
int pdVisionVRSpaceIndex(void) { return s_variant; }
int pdVisionVRStyleFull(void) { return s_styleFull; }

void pdVisionVRNoteExited(void)
{
	if (s_wanted) {
		NSLog(@"perfectdark: [vr] exit finalized — VR no longer wanted");
	}
	s_wanted = 0;
}

float pdVisionVREyeAspect(void)
{
	return (s_loopRunning && s_world) ? s_eyeAspect : 0.0f;
}

// ---------------------------------------------------------------------------
// The eye law
// ---------------------------------------------------------------------------

static simd_float4x4 pdvr_rotY(float rad)
{
	const float c = cosf(rad), s = sinf(rad);
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0] = simd_make_float4(c, 0, -s, 0);
	m.columns[2] = simd_make_float4(s, 0, c, 0);
	return m;
}

static simd_float4x4 pdvr_rotX(float rad)
{
	const float c = cosf(rad), s = sinf(rad);
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[1] = simd_make_float4(0, c, s, 0);
	m.columns[2] = simd_make_float4(0, -s, c, 0);
	return m;
}

/**
 * The compositor's OWN depth convention, classified from its matrix and then
 * checked empirically (points pushed down -Z). Column-major simd.
 *   forward-Z       : c2z = f/(n-f) < 0,  c3z = n*f/(n-f) < 0
 *   reverse-Z finite: c2z = n/(f-n) > 0,  c3z = n*f/(f-n) > 0
 *   reverse-Z, far = inf: c2z = 0,        c3z = n
 */
static void pdvr_classify_depth(simd_float4x4 pc, int *kind, float *outNear, float *outFar)
{
	const float c2z = pc.columns[2][2], c3z = pc.columns[3][2];
	if (fabsf(c2z) < 1e-6f) {
		*kind = 2;
		*outNear = fabsf(c3z);
		*outFar = INFINITY;
	} else if (c2z < 0.0f) {
		*kind = 0;
		const float n = c3z / c2z;
		*outNear = n;
		*outFar = (fabsf(1.0f + c2z) > 1e-6f) ? (c2z * n / (1.0f + c2z)) : INFINITY;
	} else {
		*kind = 1;
		const float f = c3z / c2z;
		*outFar = f;
		*outNear = (fabsf(1.0f + c2z) > 1e-6f) ? (c2z * f / (1.0f + c2z)) : 0.0f;
	}
}

// Same arithmetic, same order and NO contraction, as gfx_pc's gfx_matrix_mul
// (the engine is built -ffp-contract=off), so the published EyeVP and the
// engine's substituted matrix can be compared bit for bit.
#pragma clang fp contract(off)
static void pdvr_mul(float res[4][4], const float a[4][4], const float b[4][4])
{
	float tmp[4][4];
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			tmp[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j];
		}
	}
	memcpy(res, tmp, sizeof(tmp));
}

/** P_eye, row-vector, exactly as gfx_vr_projection builds it. */
static void pdvr_eye_projection(const float tan[4], float p22, float p32, float Pe[4][4])
{
	memset(Pe, 0, 16 * sizeof(float));
	const float tL = tan[0], tR = tan[1], tB = tan[2], tT = tan[3];
	Pe[0][0] = 2.0f / (tR - tL);
	Pe[2][0] = (tR + tL) / (tR - tL);
	Pe[1][1] = 2.0f / (tT - tB);
	Pe[2][1] = (tT + tB) / (tT - tB);
	Pe[2][2] = p22;
	Pe[2][3] = -1.0f;
	Pe[3][2] = p32;
}
#pragma clang fp contract(on)

/** The world depth row the dump's EyeVP uses: the override, else the game's. */
static void pdvr_world_depth(float *p22, float *p32)
{
	const float n = s_near, f = s_far;
	if (n > 0.0f && f > n) {
		*p22 = (n + f) / (n - f);
		*p32 = 2.0f * n * f / (n - f);
		return;
	}
	if (s_worldP32 != 0.0f) {
		*p22 = s_worldP22;
		*p32 = s_worldP32;
		return;
	}
	// Before the engine has drawn a WORLD load: vi.c's own default range.
	const float dn = 30.0f, df = 10000.0f;
	*p22 = (dn + df) / (dn - df);
	*p32 = 2.0f * dn * df / (dn - df);
}

/**
 * A . V for one eye: E = inverse(the eye's pose relative to the game camera,
 * in PD units), row-vector. The rotation is the eye's; the translation is the
 * metric eye position (plus `height`) times the world scale.
 */
static void pdvr_compose_E(simd_float4x4 eyeTrack, float E[4][4])
{
	simd_float4x4 pose = eyeTrack;
	simd_float3 t = eyeTrack.columns[3].xyz;
	t.y += s_height;
	pose.columns[3] = simd_make_float4(t * s_scale, 1.0f);
	simd_float4x4 inv = simd_inverse(pose);
	memcpy(E, &inv, sizeof(inv));
}

// ---------------------------------------------------------------------------
// Pipelines
// ---------------------------------------------------------------------------
static id<MTLRenderPipelineState> s_blitPipeline;
static id<MTLRenderPipelineState> s_solidPipeline;
static id<MTLDepthStencilState> s_depthState;
static id<MTLSamplerState> s_sampler;
static id<MTLTexture> s_copy[2], s_copySRGB[2];
static uint32_t s_copyGen;
static int s_copyW, s_copyH;

// A full-screen triangle at a constant depth, sampling the eye with NO V flip
// (the M3 lesson: the EGLImage-wrapped eye's last row is the picture's top, so
// NDC +1 samples v = 1 — exactly PDImmersive.m's pd_fs_tex mapping).
static NSString *const kPDVRShader =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
	 "vertex VOut pdvr_vs(uint vid [[vertex_id]], constant float& z [[buffer(0)]]) {\n"
	 "  const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
	 "  VOut o; o.pos = float4(p[vid], z, 1.0);\n"
	 "  o.uv = float2((p[vid].x + 1.0) * 0.5, (p[vid].y + 1.0) * 0.5);\n"
	 "  return o;\n"
	 "}\n"
	 // Alpha forced to 1: the R0 world is opaque (finding 8 measures the eye's
	 // own alpha; the clear-to-alpha-0 passthrough is charter D3's, not R0's).
	 "fragment float4 pdvr_fs(VOut in [[stage_in]], texture2d<float> eye [[texture(0)]],\n"
	 "                        sampler smp [[sampler(0)]]) {\n"
	 "  return float4(eye.sample(smp, in.uv).rgb, 1.0);\n"
	 "}\n"
	 // The readback: bytes as they are, alpha included.
	 "fragment float4 pdvr_fs_raw(VOut in [[stage_in]], texture2d<float> eye [[texture(0)]],\n"
	 "                            sampler smp [[sampler(0)]]) {\n"
	 "  return eye.sample(smp, in.uv);\n"
	 "}\n"
	 "fragment float4 pdvr_fs_solid(VOut in [[stage_in]], constant float4& c [[buffer(0)]]) {\n"
	 "  return c;\n"
	 "}\n";

static id<MTLRenderPipelineState> pdvr_pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *fs,
	MTLPixelFormat colorFmt, MTLPixelFormat depthFmt)
{
	NSError *err = nil;
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"pdvr_vs"];
	pd.fragmentFunction = [lib newFunctionWithName:fs];
	pd.colorAttachments[0].pixelFormat = colorFmt;
	pd.depthAttachmentPixelFormat = depthFmt;
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!ps) {
		NSLog(@"perfectdark: [vr] pipeline %@ FAILED: %@", fs, err.localizedDescription);
	}
	return ps;
}

static void pdvr_build(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kPDVRShader options:nil error:&err];
	if (!lib) {
		NSLog(@"perfectdark: [vr] shader FAILED: %@", err.localizedDescription);
		return;
	}
	s_blitPipeline = pdvr_pipeline(dev, lib, @"pdvr_fs", colorFmt, depthFmt);
	s_solidPipeline = pdvr_pipeline(dev, lib, @"pdvr_fs_solid", colorFmt, depthFmt);
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionAlways;
	dd.depthWriteEnabled = YES;           // the compositor reprojects on depth
	s_depthState = [dev newDepthStencilStateWithDescriptor:dd];
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = MTLSamplerMinMagFilterLinear;
	sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
	sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	s_sampler = [dev newSamplerStateWithDescriptor:sd];
	NSLog(@"perfectdark: [vr] pipelines built (color=%lu depth=%lu)",
		(unsigned long)colorFmt, (unsigned long)depthFmt);
}

static bool pdvr_ensure_copy(id<MTLDevice> dev, id<MTLTexture> src)
{
	if (s_copy[0] && s_copy[1] && s_copyW == (int)src.width && s_copyH == (int)src.height) {
		return true;
	}
	MTLTextureDescriptor *td =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
		                                                   width:src.width
		                                                  height:src.height
		                                               mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
	td.storageMode = MTLStorageModePrivate;
	// The bytes are display-encoded already (what the 2D window shows) and the
	// drawable is _sRGB, so sampling through an _sRGB view is a passthrough
	// (PDImmersive.m's own reasoning, unchanged).
	const MTLPixelFormat srgb = (src.pixelFormat == MTLPixelFormatBGRA8Unorm)
		? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm_sRGB;
	for (int e = 0; e < 2; e++) {
		s_copy[e] = [dev newTextureWithDescriptor:td];
		if (!s_copy[e]) {
			s_copy[0] = s_copy[1] = nil;
			return false;
		}
		s_copySRGB[e] = [s_copy[e] newTextureViewWithPixelFormat:srgb];
	}
	s_copyW = (int)src.width;
	s_copyH = (int)src.height;
	s_copyGen = 0;
	NSLog(@"perfectdark: [vr] eye copies %dx%d x2 fmt=%lu", s_copyW, s_copyH,
		(unsigned long)src.pixelFormat);
	return true;
}

// ---------------------------------------------------------------------------
// The per-eye readback (`vr eyedump`): the engine's own pixels, both eyes.
// ---------------------------------------------------------------------------
static void pdvr_capture(id<MTLCommandQueue> queue)
{
	for (int e = 0; e < 2; e++) {
		s_capHash[e] = s_capMean[e] = s_capAlphaMean[e] = 0;
		s_capAlphaMin[e] = 255;
		s_capW[e] = s_capH[e] = 0;
	}
	if (!s_copy[0] || !s_copy[1]) {
		return;
	}
	id<MTLDevice> dev = s_copy[0].device;
	NSError *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kPDVRShader options:nil error:&err];
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"pdvr_vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"pdvr_fs_raw"];
	pd.colorAttachments[0].pixelFormat = s_copy[0].pixelFormat;
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!ps) {
		NSLog(@"perfectdark: [vr] capture pipeline FAILED: %@", err.localizedDescription);
		return;
	}
	const BOOL bgra = (s_copy[0].pixelFormat == MTLPixelFormatBGRA8Unorm);
	for (int e = 0; e < 2; e++) {
		id<MTLTexture> src = s_copy[e];
		const int W = 512;
		const int H = (int)lround(512.0 * (double)src.height / (double)src.width);
		MTLTextureDescriptor *td =
			[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
			                                                   width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
		if (!dst) {
			continue;
		}
		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = dst;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
		const float z = 0.5f;
		[enc setRenderPipelineState:ps];
		[enc setVertexBytes:&z length:sizeof(z) atIndex:0];
		[enc setFragmentTexture:src atIndex:0];
		[enc setFragmentSamplerState:s_sampler atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];

		const size_t rowBytes = (size_t)W * 4, n = rowBytes * (size_t)H;
		uint8_t *px = malloc(n);
		uint8_t *rgba = malloc(n);
		if (!px || !rgba) {
			free(px);
			free(rgba);
			continue;
		}
		[dst getBytes:px bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		uint32_t hash = 2166136261u;
		uint64_t sum = 0, asum = 0;
		uint32_t amin = 255;
		// The picture's TOP is the texture's LAST row (the M3 fact), so the PNG
		// is written bottom-up to read the right way round.
		for (int y = 0; y < H; y++) {
			const uint8_t *row = px + (size_t)(H - 1 - y) * rowBytes;
			uint8_t *out = rgba + (size_t)y * rowBytes;
			for (int x = 0; x < W; x++) {
				const uint8_t *q = row + x * 4;
				for (int c = 0; c < 4; c++) {
					hash = (hash ^ q[c]) * 16777619u;
				}
				sum += (uint64_t)q[0] + q[1] + q[2];
				asum += q[3];
				if (q[3] < amin) amin = q[3];
				out[x * 4 + 0] = bgra ? q[2] : q[0];
				out[x * 4 + 1] = q[1];
				out[x * 4 + 2] = bgra ? q[0] : q[2];
				out[x * 4 + 3] = 255;
			}
		}
		s_capHash[e] = hash;
		s_capMean[e] = (uint32_t)(sum / ((uint64_t)W * (uint64_t)H * 3u));
		s_capAlphaMean[e] = (uint32_t)(asum / ((uint64_t)W * (uint64_t)H));
		s_capAlphaMin[e] = amin;
		s_capW[e] = (int)src.width;
		s_capH[e] = (int)src.height;
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(rgba, W, H, 8, rowBytes, cs,
			kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
		CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
		if (img) {
			NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
				NSUserDomainMask, YES).firstObject;
			NSString *path = [docs stringByAppendingPathComponent:
				[NSString stringWithFormat:@"vr-eye%d.png", e]];
			[UIImagePNGRepresentation([UIImage imageWithCGImage:img]) writeToFile:path atomically:YES];
			CGImageRelease(img);
		}
		if (ctx) CGContextRelease(ctx);
		CGColorSpaceRelease(cs);
		free(rgba);
		free(px);
	}
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

static void pdvr_cadence(double optInSec)
{
	static double last = 0.0, sum = 0.0;
	static int n = 0;
	if (last > 0.0 && optInSec > last) {
		const double d = optInSec - last;
		if (d > 0.00005 && d < 1.0) {
			sum += d;
			if (++n >= 20) {
				pdVision3dImmHz = (float)(n / sum);
				sum = 0.0;
				n = 0;
			}
		}
	}
	last = optInSec;
}

void pdVisionVRImmersiveRun(void *lr)
{
	cp_layer_renderer_t layer = (__bridge cp_layer_renderer_t)lr;

	pdVision3dImmStop = 0;
	pdVision3dImmRunning = 1;
	pdVision3dImmFrames = 0;
	pdVision3dImmNoDrawable = 0;
	pdVision3dImmHz = 0.0f;
	s_vrFrames = 0;
	s_presents = 0;
	s_compGpuMs = 0.0;
	s_reason = "starting";
	memset(&s_contract, 0, sizeof(s_contract));
	// Review fix 2: the generation counter is NOT reset per session. 0057's
	// pd_vr_cache keys on gen; restarting at 1 would let a re-entry hit the
	// previous session's cached matrix after `vr set`/`vr inject`. The first
	// publish of this session is s_pub.gen + 1, strictly newer than any gen the
	// cache can hold (0 is skipped on wrap).
	// Review fix 3: the engine latch is cleared too, so the first pairs of a
	// re-entry render the game's matrix, never the previous session's law.
	os_unfair_lock_lock(&s_lawLock);
	{
		const unsigned int keepGen = s_pub.gen;
		memset(&s_pub, 0, sizeof(s_pub));
		s_pub.gen = keepGen;
		memset(&s_lat, 0, sizeof(s_lat));
	}
	os_unfair_lock_unlock(&s_lawLock);
	s_engMPNotes[0] = s_engMPNotes[1] = 0;
	s_loopRunning = 1;
	int notifyEnded = 0;
	id<MTLCommandQueue> queue = nil;
	pdvr_pace_start();

	ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
	ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
	ar_session_t session = ar_session_create();
	ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
	ar_session_run(session, providers);

	// The compositor is the engine's clock here too (D-050), switched by the
	// loop itself so a Crown dismissal cannot strand the engine.
	pdPacingSetExternalSource(1);
	NSLog(@"perfectdark: [vr] VR loop started (space=%d style=%s world=%d scale=%.1f)",
		s_variant, s_styleFull ? "full" : "mixed", s_world, (double)s_scale);

	int running = 1;
	while (running) {
		if (pdVision3dImmStop) {
			NSLog(@"perfectdark: [vr] stop requested — leaving cleanly (frames=%d)", s_vrFrames);
			s_reason = "stopped";
			break;
		}
		switch (cp_layer_renderer_get_state(layer)) {
			case cp_layer_renderer_state_paused:
				cp_layer_renderer_wait_until_running(layer);
				continue;
			case cp_layer_renderer_state_invalidated:
				NSLog(@"perfectdark: [vr] layer invalidated — leaving loop (frames=%d)", s_vrFrames);
				s_reason = "invalidated";
				notifyEnded = 1;
				running = 0;
				continue;
			case cp_layer_renderer_state_running:
			default:
				break;
		}

		@autoreleasepool {
			cp_frame_t frame = cp_layer_renderer_query_next_frame(layer);
			if (frame == NULL) {
				continue;
			}
			cp_frame_timing_t timing = cp_frame_predict_timing(frame);
			cp_frame_start_update(frame);
			cp_frame_end_update(frame);
			cp_time_t optIn = cp_frame_timing_get_optimal_input_time(timing);
			pdvr_cadence(cp_time_to_cf_time_interval(optIn));
			cp_time_wait_until(optIn);
			pdPacingSignalExternal();
			cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
			if (drawable == NULL) {
				// NO end_submission (PDImmersive.m's dev1 SIGABRT).
				pdVision3dImmNoDrawable++;
				continue;
			}

			id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
			if (queue == nil) {
				queue = [t0.device newCommandQueue];
				pdvr_build(t0.device, t0.pixelFormat,
					cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
			}

			CFTimeInterval presTime = cp_time_to_cf_time_interval(
				cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
			ar_device_anchor_t anchor = ar_device_anchor_create();
			ar_device_anchor_query_status_t anchorStatus =
				ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
			cp_drawable_set_device_anchor(drawable, anchor);
			s_anchored = (anchorStatus == ar_device_anchor_query_status_success);
			s_originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

			const size_t views = cp_drawable_get_view_count(drawable);
			if (views > 0) {
				MTLViewport v0 = cp_view_texture_map_get_viewport(
					cp_view_get_view_texture_map(cp_drawable_get_view(drawable, 0)));
				pdVisionEyeNoteCompositorViewSize((int)v0.width, (int)v0.height);
			}

			// ---- the pose: FROZEN in R0 (identity), or the injected one ------
			simd_float4x4 head = matrix_identity_float4x4;
			if (s_injOn) {
				head = simd_mul(pdvr_rotY(s_injYawDeg * (float)M_PI / 180.0f),
				                pdvr_rotX(s_injPitchDeg * (float)M_PI / 180.0f));
				head.columns[3] = simd_make_float4(s_injPos[0], s_injPos[1], s_injPos[2], 1.0f);
				s_poseSrc = 2;
			} else {
				s_poseSrc = 0;
			}
			s_head = head;

			// ---- the contract, and the eye law ------------------------------
			s_synthEye2 = (views < 2);
			PDVRLaw law;
			memset(&law, 0, sizeof(law));
			for (int e = 0; e < 2; e++) {
				const size_t v = ((size_t)e < views) ? (size_t)e : 0;
				cp_view_t view = cp_drawable_get_view(drawable, v);
				simd_float4x4 deviceFromEye = cp_view_get_transform(view);
				if (s_synthEye2) {
					// The simulator is MONO (one view, identity transform): the
					// pair is synthesized at +/-31.5 mm along eye-space X so the
					// IPD assertion has something real to assert.
					simd_float4x4 off = matrix_identity_float4x4;
					off.columns[3] = simd_make_float4(e == 0 ? -kHalfIpd : kHalfIpd, 0, 0, 1);
					deviceFromEye = simd_mul(deviceFromEye, off);
				}
				s_eyeTrack[e] = simd_mul(head, deviceFromEye);

				simd_float4x4 pc = matrix_identity_float4x4;
				if (__builtin_available(visionOS 2.0, *)) {
					pc = cp_drawable_compute_projection(drawable,
						cp_axis_direction_convention_right_up_back, v);
				}
				float tR = 1, tL = -1, tT = 1, tB = -1;
				if (fabsf(pc.columns[0][0]) > 1e-6f && fabsf(pc.columns[1][1]) > 1e-6f) {
					tR = (pc.columns[2][0] + 1.0f) / pc.columns[0][0];
					tL = (pc.columns[2][0] - 1.0f) / pc.columns[0][0];
					tT = (pc.columns[2][1] + 1.0f) / pc.columns[1][1];
					tB = (pc.columns[2][1] - 1.0f) / pc.columns[1][1];
				}
				cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
				MTLViewport vp = cp_view_texture_map_get_viewport(tmap);
				s_contract.vpW[e] = vp.width;
				s_contract.vpH[e] = vp.height;
				s_contract.texIdx[e] = cp_view_texture_map_get_texture_index(tmap);
				s_contract.slice[e] = cp_view_texture_map_get_slice_index(tmap);
				s_contract.tanL[e] = tL;
				s_contract.tanR[e] = tR;
				s_contract.tanB[e] = tB;
				s_contract.tanT[e] = tT;
				s_contract.rawC2z[e] = pc.columns[2][2];
				s_contract.rawC3z[e] = pc.columns[3][2];
				pdvr_classify_depth(pc, &s_contract.depthKind[e], &s_contract.depthNear[e],
					&s_contract.depthFar[e]);
				// Measured, not read: points down -Z through the compositor's
				// OWN matrix. Near -> 1 / far -> 0 is reverse-Z.
				const float zs[3] = { -1.0f, -10.0f, -1000.0f };
				for (int k = 0; k < 3; k++) {
					simd_float4 clip = simd_mul(pc, simd_make_float4(0, 0, zs[k], 1));
					const float ndc = (fabsf(clip.w) > 1e-9f) ? clip.z / clip.w : 0.0f;
					if (k == 0) s_contract.zndc1m[e] = ndc;
					else if (k == 1) s_contract.zndc10m[e] = ndc;
					else s_contract.zndc1000m[e] = ndc;
				}

				law.tan[e][0] = tL;
				law.tan[e][1] = tR;
				law.tan[e][2] = tB;
				law.tan[e][3] = tT;
				pdvr_compose_E(s_eyeTrack[e], law.E[e]);
				memcpy(s_E[e], law.E[e], sizeof(s_E[e]));
				float p22 = 0, p32 = 0, Pe[4][4];
				pdvr_world_depth(&p22, &p32);
				pdvr_eye_projection(law.tan[e], p22, p32, Pe);
				pdvr_mul(s_eyeVP[e], law.E[e], Pe);
				s_Pe00[e] = Pe[0][0];
			}
			law.depth[0] = s_near;
			law.depth[1] = s_far;
			s_contract.views = views;
			s_contract.textures = cp_drawable_get_texture_count(drawable);
			s_contract.ratemaps = cp_drawable_get_rasterization_rate_map_count(drawable);
			s_contract.colorFmt = (unsigned long)t0.pixelFormat;
			s_contract.depthFmt = (unsigned long)cp_drawable_get_depth_texture(drawable, 0).pixelFormat;
			s_contract.layout = (s_contract.textures > 1) ? 0 : ((views > 1) ? 1 : 0);
			{
				simd_float2 dr = cp_drawable_get_depth_range(drawable);
				s_contract.rangeFar = dr.x;
				s_contract.rangeNear = dr.y;
			}
			// R0 writes ONE constant depth for the whole blit (depth handoff is
			// R1 work): a plane at 2 m in the compositor's own convention.
			s_contract.blitDepth = (s_contract.depthKind[0] == 2)
				? s_contract.rawC3z[0] / 2.0f : 0.5f;
			s_contract.valid = 1;

			// Publish, bumping the generation only when the law moved, so the
			// engine's per-projection cache stays warm under a frozen pose.
			os_unfair_lock_lock(&s_lawLock);
			law.gen = s_pub.gen;
			law.valid = 1;
			if (!s_pub.valid || memcmp(law.E, s_pub.E, sizeof(law.E)) != 0
					|| memcmp(law.tan, s_pub.tan, sizeof(law.tan)) != 0
					|| memcmp(law.depth, s_pub.depth, sizeof(law.depth)) != 0) {
				law.gen = s_pub.gen + 1;
				if (law.gen == 0) law.gen = 1;
			}
			s_pub = law;
			os_unfair_lock_unlock(&s_lawLock);

			// The eye wears the frustum's aspect, so a whole-slice blit is
			// undistorted. Re-wrapped by the engine at a frame boundary.
			const float asp = (law.tan[0][1] - law.tan[0][0]) / (law.tan[0][3] - law.tan[0][2]);
			if (s_world && fabsf(asp - s_eyeAspect) > 0.005f * asp) {
				s_eyeAspect = asp;
				NSLog(@"perfectdark: [vr] eye aspect -> %.4f (tangents %.4f,%.4f,%.4f,%.4f)",
					(double)asp, (double)law.tan[0][0], (double)law.tan[0][1],
					(double)law.tan[0][2], (double)law.tan[0][3]);
				pdVisionEyeVRResize();
			}

			id<MTLCommandBuffer> cmd = [queue commandBuffer];

			// ---- the eye handoff (PDImmersive.m's, without the mips) --------
			int haveWorld = 0;
			if (s_world) {
				void *evt = NULL;
				unsigned long long val = 0;
				unsigned int gen = 0;
				pdVisionEyeSampleBegin();
				void *pub = pdVisionEyeAcquire(PD_EYE_LEFT, &evt, &val, &gen);
				void *pubR = pdVisionEyeAcquire(PD_EYE_RIGHT, NULL, NULL, NULL);
				id<MTLSharedEvent> event = evt ? (__bridge_transfer id<MTLSharedEvent>)evt : nil;
				if (pub && pubR) {
					id<MTLTexture> src[2] = { (__bridge id<MTLTexture>)pub,
					                          (__bridge id<MTLTexture>)pubR };
					if (pdvr_ensure_copy(t0.device, src[0])) {
						if (gen != s_copyGen) {
							if (event) {
								[cmd encodeWaitForEvent:event value:val];
							}
							id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
							for (int e = 0; e < 2; e++) {
								[blit copyFromTexture:src[e] sourceSlice:0 sourceLevel:0
								         sourceOrigin:MTLOriginMake(0, 0, 0)
								           sourceSize:MTLSizeMake(src[e].width, src[e].height, 1)
								            toTexture:s_copy[e] destinationSlice:0 destinationLevel:0
								    destinationOrigin:MTLOriginMake(0, 0, 0)];
							}
							[blit endEncoding];
							s_copyGen = gen;
							pdVisionEyeCountSample(1);
						} else {
							pdVisionEyeCountSample(0);
						}
						haveWorld = 1;
					}
				}
				pdVisionEyeSampleEnd();
			}
			s_reason = s_world ? (haveWorld ? "world" : "no_eye_texture") : "clear_only";

			const size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
			pdVision3dFoveationRateMaps = (int)rmCount;
			for (size_t v = 0; v < views; v++) {
				cp_view_t view = cp_drawable_get_view(drawable, v);
				cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
				const size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
				const size_t slice = cp_view_texture_map_get_slice_index(tmap);
				const MTLViewport vp = cp_view_texture_map_get_viewport(tmap);

				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
				pass.colorAttachments[0].slice = slice;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
				if (rmCount > 0) {
					pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
						drawable, texIdx < rmCount ? texIdx : 0);
				}
				id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
				if (depthTex) {
					// Cleared AND stored. 0 is FAR in the compositor's reverse-Z
					// (measured: `vr contract`).
					pass.depthAttachment.texture = depthTex;
					pass.depthAttachment.slice = slice;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					pass.depthAttachment.clearDepth = 0.0;
				}
				id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
				[enc setViewport:vp];
				[enc setDepthStencilState:s_depthState];
				const float z = s_contract.blitDepth;
				[enc setVertexBytes:&z length:sizeof(z) atIndex:0];
				// On the headset views are [L, R]; the sim's one view shows eye L
				// unless `3d showeye` forces one (the L-vs-R room capture).
				const int showEye = pdVisionEyeShowEye();
				const int eyeIdx = (showEye >= 0) ? showEye : (int)(v & 1);
				if (haveWorld && s_blitPipeline) {
					[enc setRenderPipelineState:s_blitPipeline];
					[enc setFragmentTexture:(s_copySRGB[eyeIdx] ?: s_copy[eyeIdx]) atIndex:0];
					[enc setFragmentSamplerState:s_sampler atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				} else if (s_solidPipeline) {
					// R0a: a distinct half-transparent colour per eye
					// (premultiplied), so passthrough shows through under .mixed.
					simd_float4 c = (eyeIdx == 0) ? simd_make_float4(0.375f, 0.05f, 0.05f, 0.5f)
					                              : simd_make_float4(0.05f, 0.10f, 0.425f, 0.5f);
					[enc setRenderPipelineState:s_solidPipeline];
					[enc setFragmentBytes:&c length:sizeof(c) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				}
				[enc endEncoding];
			}

			[cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
				const double g = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
				if (g > 0.0 && g < 1000.0) {
					s_compGpuMs = (s_compGpuMs <= 0.0) ? g : (s_compGpuMs * 0.9 + g * 0.1);
				}
			}];
			cp_drawable_encode_present(drawable, cmd);
			[cmd commit];

			s_vrFrames++;
			s_presents++;
			pdVision3dImmFrames++;
			if (s_vrFrames == 3 || (s_vrFrames % 600) == 0) {
				NSLog(@"perfectdark: [vr] frame %d views=%zu world=%d have=%d anchored=%d %.1f Hz",
					s_vrFrames, views, s_world, haveWorld, s_anchored, (double)pdVision3dImmHz);
			}
			cp_frame_end_submission(frame);

			if (s_capReq) {
				s_capReq = 0;
				pdvr_capture(queue);
				s_capDone = 1;
			}
		}
	}

	// Review fix 1: stop the tracking session on every exit path (stop,
	// invalidated, break) so repeated `vr on`/`vr off` never stacks sessions.
	if (session) {
		ar_session_stop(session);
		session = nil;
	}
	os_unfair_lock_lock(&s_lawLock);
	s_pub.valid = 0;
	os_unfair_lock_unlock(&s_lawLock);
	s_loopRunning = 0;
	s_eyeAspect = 0.0f;
	s_contract.valid = 0;
	s_copy[0] = s_copy[1] = nil;
	s_copySRGB[0] = s_copySRGB[1] = nil;
	pdPacingSetExternalSource(0);
	if (notifyEnded) {
		pdVision3dImmersiveEnded();
	}
	// LAST: pdVision3dApplyMode(0) waits on exactly this.
	pdVision3dImmRunning = 0;
}

// ---------------------------------------------------------------------------
// The `vr` dump family (charter D10). One flat key=value line per reply, the
// last field a monotone seq.
// ---------------------------------------------------------------------------
#ifndef PD_PUBLIC

static const char *pdvr_mode_name(void)
{
	if (!pdVision3dActive()) return "flat";
	return s_wanted ? "vr" : "panel3D";
}

static NSString *pdvr_dump_pose(void)
{
	const simd_float3 e0 = s_eyeTrack[0].columns[3].xyz;
	const simd_float3 e1 = s_eyeTrack[1].columns[3].xyz;
	// The convention assertion is NOT "the world delta is 63 mm along X" (it is
	// not, under a yawed head) but "the delta reduces to +63 mm along X in EYE
	// space": the world delta rotated back through eye 0's basis.
	const simd_float3 d = e1 - e0;
	const float dx = simd_dot(d, s_eyeTrack[0].columns[0].xyz);
	const float dy = simd_dot(d, s_eyeTrack[0].columns[1].xyz);
	const float dz = simd_dot(d, s_eyeTrack[0].columns[2].xyz);
	const float len = simd_length(d);
	const BOOL ipd = fabsf(dx - 2.0f * kHalfIpd) < 0.0005f && fabsf(dy) < 0.0002f && fabsf(dz) < 0.0002f;
	// The clip-x translation delta of the composed matrices, against the metric
	// separation times the scale times P_eye's x scale.
	const float clipdx = s_eyeVP[0][3][0] - s_eyeVP[1][3][0];
	const float expect = 2.0f * kHalfIpd * s_scale * s_Pe00[0];
	const BOOL clipok = fabsf(clipdx - expect) <= 1e-4f * fmaxf(1.0f, fabsf(expect));
	// Did the engine substitute EXACTLY the published matrix? (plain WORLD loads)
	int subst[2];
	for (int e = 0; e < 2; e++) {
		subst[e] = (s_engMPNotes[e] > 0) ? (memcmp(s_engMP[e], s_eyeVP[e], sizeof(s_eyeVP[e])) == 0) : -1;
	}
	float p22 = 0, p32 = 0;
	pdvr_world_depth(&p22, &p32);
	return [NSString stringWithFormat:
		@"vr=pose injected=%d anchored=%d views=%zu psrc=%d synth_eye2=%d"
		 " head=%.4f,%.4f,%.4f eye0=%.4f,%.4f,%.4f eye1=%.4f,%.4f,%.4f"
		 " ipd_eye_dx=%.5f ipd_eye_dy=%.5f ipd_eye_dz=%.5f ipd_len=%.5f ipd_check=%s"
		 " scale=%.2f height=%.3f near=%.1f far=%.1f world_p22=%.6f world_p32=%.3f"
		 " pe00=%.6f clipx_delta=%.5f clipx_expect=%.5f clipx_check=%s"
		 " eL_row3=%.4f,%.4f,%.4f eR_row3=%.4f,%.4f,%.4f"
		 " eyeL_row0=%.5f,%.5f,%.5f,%.5f eyeL_row3=%.5f,%.5f,%.5f,%.5f"
		 " eyeR_row0=%.5f,%.5f,%.5f,%.5f eyeR_row3=%.5f,%.5f,%.5f,%.5f"
		 " engL_row3=%.5f,%.5f,%.5f,%.5f engR_row3=%.5f,%.5f,%.5f,%.5f"
		 " eng_notes=%llu,%llu subst_exact=%d,%d latched_gen=%u engine_law=%d seq=%llu",
		s_injOn, s_anchored, s_contract.views, s_poseSrc, s_synthEye2,
		s_head.columns[3].x, s_head.columns[3].y, s_head.columns[3].z,
		e0.x, e0.y, e0.z, e1.x, e1.y, e1.z,
		dx, dy, dz, len, ipd ? "PASS" : "FAIL",
		(double)s_scale, (double)s_height, (double)s_near, (double)s_far, (double)p22, (double)p32,
		(double)s_Pe00[0], clipdx, expect, clipok ? "PASS" : "FAIL",
		s_E[0][3][0], s_E[0][3][1], s_E[0][3][2], s_E[1][3][0], s_E[1][3][1], s_E[1][3][2],
		s_eyeVP[0][0][0], s_eyeVP[0][0][1], s_eyeVP[0][0][2], s_eyeVP[0][0][3],
		s_eyeVP[0][3][0], s_eyeVP[0][3][1], s_eyeVP[0][3][2], s_eyeVP[0][3][3],
		s_eyeVP[1][0][0], s_eyeVP[1][0][1], s_eyeVP[1][0][2], s_eyeVP[1][0][3],
		s_eyeVP[1][3][0], s_eyeVP[1][3][1], s_eyeVP[1][3][2], s_eyeVP[1][3][3],
		s_engMP[0][3][0], s_engMP[0][3][1], s_engMP[0][3][2], s_engMP[0][3][3],
		s_engMP[1][3][0], s_engMP[1][3][1], s_engMP[1][3][2], s_engMP[1][3][3],
		s_engMPNotes[0], s_engMPNotes[1], subst[0], subst[1], s_lat.gen,
		pdVisionVRActive(), pdvr_seq()];
}

static NSString *pdvr_dump_mode(void)
{
	static const char *kSpaces[3] = { "PDVR", "PDVRTestA", "PDVRTestB" };
	int ew = 0, eh = 0;
	pdVisionEyeGetSize(&ew, &eh);
	return [NSString stringWithFormat:
		@"vr=mode mode=%s wanted=%d space=%s style=%s loop_running=%d imm_running=%d"
		 " loop_stop=%d reason=%s world=%d engine_law=%d eye_renders=%llu eye_size=%dx%d"
		 " eye_aspect=%.4f in_flight=%d anchored=%d injected=%d contract=%d frames=%d"
		 " no_drawable=%d stage=0x%x menu_open=%d seq=%llu",
		pdvr_mode_name(), s_wanted, kSpaces[s_variant % 3], s_styleFull ? "full" : "mixed",
		s_loopRunning, (int)pdVision3dImmRunning, (int)pdVision3dImmStop, s_reason, s_world,
		pdVisionVRActive(), pdVisionEyeRenders(), ew, eh, (double)s_eyeAspect,
		pdVisionEyeInFlight(), s_anchored, s_injOn, s_contract.valid, s_vrFrames,
		(int)pdVision3dImmNoDrawable, mainGetStageNum(), menuIosDialogIsOpen(), pdvr_seq()];
}

static NSString *pdvr_dump_contract(void)
{
	static const char *kKind[3] = { "forwardZ", "reverseZ_finite", "reverseZ_infinite_far" };
	NSMutableString *s = [NSMutableString stringWithFormat:
		@"vr=contract valid=%d views=%zu textures=%zu ratemaps=%zu layout=%s foveation=%d/%d"
		 " colorFmt=%lu depthFmt=%lu",
		s_contract.valid, s_contract.views, s_contract.textures, s_contract.ratemaps,
		// What PDCompositorConfiguration ASKED for (the sim: layered, no
		// foveation); views/textures/slices above are what the drawable carries.
		pdVision3dLayoutDedicated ? "dedicated" : "layered",
		(int)pdVision3dFoveationSupported, (int)pdVision3dFoveationConfigured,
		s_contract.colorFmt, s_contract.depthFmt];
	for (int e = 0; e < 2; e++) {
		[s appendFormat:@" eye%d_vp=%.0fx%.0f eye%d_tex=%zu eye%d_slice=%zu eye%d_tan=%.4f,%.4f,%.4f,%.4f",
			e, s_contract.vpW[e], s_contract.vpH[e], e, s_contract.texIdx[e], e, s_contract.slice[e],
			e, s_contract.tanL[e], s_contract.tanR[e], s_contract.tanB[e], s_contract.tanT[e]];
	}
	for (int e = 0; e < 2; e++) {
		[s appendFormat:@" eye%d_depth=%s eye%d_c2z=%.6f eye%d_c3z=%.6f eye%d_near_m=%.4f eye%d_far_m=%.1f"
			" eye%d_zndc_1m=%.6f eye%d_zndc_10m=%.6f eye%d_zndc_1000m=%.6f",
			e, kKind[s_contract.depthKind[e] % 3], e, s_contract.rawC2z[e], e, s_contract.rawC3z[e],
			e, s_contract.depthNear[e], e, s_contract.depthFar[e], e, s_contract.zndc1m[e],
			e, s_contract.zndc10m[e], e, s_contract.zndc1000m[e]];
	}
	int ew = 0, eh = 0;
	pdVisionEyeGetSize(&ew, &eh);
	[s appendFormat:@" cp_depth_range_far_m=%.1f cp_depth_range_near_m=%.4f"
		" engine_depth=forwardZ_gl_clear1_lequal r0_blit_depth=%.5f engine_eye_fb=%dx%d"
		" eye_copy=%dx%d seq=%llu",
		s_contract.rangeFar, s_contract.rangeNear, (double)s_contract.blitDepth, ew, eh,
		s_copyW, s_copyH, pdvr_seq()];
	return s;
}

static NSString *pdvr_dump_pace(void)
{
	double fps = 0, tps = 0, sim60 = 0, hz = 0, span = 0;
	pdvr_pace_rates(&fps, &tps, &sim60, &hz, &span);
	return [NSString stringWithFormat:
		@"vr=pace mode=%s engine_fps=%.2f tick_tps=%.2f sim60_rate=%.2f present_hz=%.2f"
		 " comp_hz=%.2f window_s=%.2f presents=%llu engine_avg_fps=%.1f comp_gpu_ms=%@"
		 " eye_renders=%llu seq=%llu",
		pdvr_mode_name(), fps, tps, sim60, hz, (double)pdVision3dImmHz, span,
		(unsigned long long)s_presents, (double)videoGetAverageFPS(),
		// The VR loop's own command buffer; the panel loop has no probe.
		s_loopRunning ? [NSString stringWithFormat:@"%.3f", s_compGpuMs] : @"na",
		pdVisionEyeRenders(), pdvr_seq()];
}

static NSString *pdvr_err(NSString *msg)
{
	return [NSString stringWithFormat:@"vr=error msg=\"%@\" seq=%llu", msg, pdvr_seq()];
}

NSString *pdVisionVRCommand(NSArray<NSString *> *args)
{
	pdvr_pace_start();
	NSString *sub = args.count >= 1 ? args[0].lowercaseString : @"";
	if (sub.length == 0) {
		return [@[ pdvr_dump_mode(), pdvr_dump_pose(), pdvr_dump_contract(), pdvr_dump_pace() ]
			componentsJoinedByString:@"\n"];
	}
	if ([sub isEqualToString:@"pose"]) return pdvr_dump_pose();
	if ([sub isEqualToString:@"mode"]) return pdvr_dump_mode();
	if ([sub isEqualToString:@"contract"]) return pdvr_dump_contract();
	if ([sub isEqualToString:@"pace"]) return pdvr_dump_pace();
	if ([sub isEqualToString:@"on"]) {
		if (pdVision3dActive() && !s_wanted) {
			return pdvr_err(@"the 3D panel mode is on: `3d off` first (3D<->VR is dismiss-then-open)");
		}
		s_wanted = 1;
		dispatch_async(dispatch_get_main_queue(), ^{ pdVision3dSetMode(true); });
		return [NSString stringWithFormat:@"vr=on requested=1 space=%d style=%s world=%d seq=%llu",
			s_variant, s_styleFull ? "full" : "mixed", s_world, pdvr_seq()];
	}
	if ([sub isEqualToString:@"off"]) {
		dispatch_async(dispatch_get_main_queue(), ^{ pdVision3dSetMode(false); });
		return [NSString stringWithFormat:@"vr=off requested=1 seq=%llu", pdvr_seq()];
	}
	if ([sub isEqualToString:@"space"]) {
		if (args.count >= 2) {
			NSString *w = args[1].uppercaseString;
			s_variant = [w isEqualToString:@"A"] ? 1 : ([w isEqualToString:@"B"] ? 2 : 0);
		}
		return [NSString stringWithFormat:@"vr=space space=%d next_open=%s seq=%llu", s_variant,
			s_variant == 1 ? "PDVRTestA" : (s_variant == 2 ? "PDVRTestB" : "PDVR"), pdvr_seq()];
	}
	if ([sub isEqualToString:@"style"]) {
		if (args.count < 2) {
			return pdvr_err(@"usage: vr style mixed|full");
		}
		s_styleFull = [args[1].lowercaseString isEqualToString:@"full"] ? 1 : 0;
		PD_VRPushStyle(s_styleFull);
		return [NSString stringWithFormat:@"vr=style style=%s space=%d seq=%llu",
			s_styleFull ? "full" : "mixed", s_variant, pdvr_seq()];
	}
	if ([sub isEqualToString:@"world"]) {
		if (args.count < 2) {
			return pdvr_err(@"usage: vr world on|off");
		}
		s_world = [args[1].lowercaseString isEqualToString:@"on"] ? 1 : 0;
		return [NSString stringWithFormat:@"vr=world world=%d seq=%llu", s_world, pdvr_seq()];
	}
	if ([sub isEqualToString:@"inject"]) {
		if (args.count >= 2 && [args[1].lowercaseString isEqualToString:@"off"]) {
			s_injOn = 0;
			usleep(60 * 1000);
			return pdvr_dump_pose();
		}
		if (args.count >= 6) {
			s_injPos[0] = args[1].floatValue;
			s_injPos[1] = args[2].floatValue;
			s_injPos[2] = args[3].floatValue;
			s_injYawDeg = args[4].floatValue;
			s_injPitchDeg = args[5].floatValue;
			s_injOn = 1;
			// One compositor frame to recompose before the dump is read (an
			// early dump reads the previous pose and looks like a sign bug).
			usleep(60 * 1000);
			return pdvr_dump_pose();
		}
		return pdvr_err(@"usage: vr inject X Y Z YAW PITCH | vr inject off");
	}
	if ([sub isEqualToString:@"set"]) {
		if (args.count < 3) {
			return pdvr_err(@"usage: vr set scale|height|near|far V");
		}
		NSString *k = args[1].lowercaseString;
		const float v = args[2].floatValue;
		if ([k isEqualToString:@"scale"] && v > 0.1f && v < 10000.0f) s_scale = v;
		else if ([k isEqualToString:@"height"] && fabsf(v) < 10.0f) s_height = v;
		else if ([k isEqualToString:@"near"] && v >= 0.0f) s_near = v;
		else if ([k isEqualToString:@"far"] && v >= 0.0f) s_far = v;
		else return pdvr_err(@"usage: vr set scale|height|near|far V (near/far 0 = the game's)");
		usleep(60 * 1000);
		return [NSString stringWithFormat:@"vr=set key=%@ scale=%.2f height=%.3f near=%.1f far=%.1f seq=%llu",
			k, (double)s_scale, (double)s_height, (double)s_near, (double)s_far, pdvr_seq()];
	}
	if ([sub isEqualToString:@"eyedump"]) {
		if (!s_loopRunning) {
			return pdvr_err(@"vr eyedump needs the VR loop running (`vr on`)");
		}
		s_capDone = 0;
		s_capReq = 1;
		for (int i = 0; i < 500 && !s_capDone; i++) {
			usleep(10 * 1000);
		}
		if (!s_capDone) {
			return pdvr_err(@"vr eyedump timed out");
		}
		const int differ = (s_capHash[0] != s_capHash[1] && s_capHash[0] && s_capHash[1]);
		return [NSString stringWithFormat:
			@"vr=eyedump eye0=%dx%d hash0=0x%08x mean0=%u alpha_mean0=%u alpha_min0=%u"
			 " eye1=%dx%d hash1=0x%08x mean1=%u alpha_mean1=%u alpha_min1=%u differ=%d"
			 " files=Documents/vr-eye0.png,Documents/vr-eye1.png seq=%llu",
			s_capW[0], s_capH[0], s_capHash[0], s_capMean[0], s_capAlphaMean[0], s_capAlphaMin[0],
			s_capW[1], s_capH[1], s_capHash[1], s_capMean[1], s_capAlphaMean[1], s_capAlphaMin[1],
			differ, pdvr_seq()];
	}
	return pdvr_err(@"usage: vr [pose|mode|contract|pace|on|off|space VR|A|B|style mixed|full|"
		"world on|off|inject X Y Z YAW PITCH|inject off|set scale|height|near|far V|eyedump]");
}

#else  // PD_PUBLIC: no bridge, no dumps.

NSString *pdVisionVRCommand(NSArray<NSString *> *args)
{
	(void)args;
	return nil;
}

#endif // !PD_PUBLIC

#endif // TARGET_OS_VISION
