// PDGfxTrace.h — upstream's own renderer counters, by upstream's own header.
//
// Until 1.0.5.2 the shell re-declared `struct GfxTraceStats` in PDShell.h with
// the 9 fields it had when round P first read it. Upstream has since grown it
// to 16 (the texture cache's peak/grows/evictions/budget...), so the bridge's
// `gfx` handed gfx_trace_stats() a 36-byte stack object to write 64 bytes into
// and crashed the app on the phone (M-057). The fix is to stop mirroring it:
// the layout here is the compiler's reading of port/fast3d/gfx_api.h from the
// overlay tree the engine itself was built from (build/src, apply-overlay.sh).
//
// gfx_api.h names `Gfx` (in gfx_run's prototype) without including anything
// that defines it; the shell never touches a display list, so an incomplete
// type is all it needs. Include this from ONE file that never sees PR/gbi.h.
#pragma once

#include <stdint.h>

typedef union Gfx Gfx;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#include "../../build/src/port/fast3d/gfx_api.h"
#pragma clang diagnostic pop

// Loud when upstream changes the struct again (ground rule 3): the layout can
// no longer be wrong, but the bridge's `gfx` reply prints the fields by name,
// and a field it does not print is a field nobody reads. Update the reply in
// PDBridge.m, then this number.
_Static_assert(sizeof(struct GfxTraceStats) == 16 * sizeof(uint32_t),
	"upstream's struct GfxTraceStats changed size: update PDBridge.m's `gfx` reply and this assert");
