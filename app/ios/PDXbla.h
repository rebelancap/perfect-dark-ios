// PDXbla.h — the Xbox 360 (XBLA) release on a phone: find it, say what it is,
// unpack it once, and show that happening.
//
// The engine already knows how to do all of this (port/src/xblaimport.c, and
// upstream's CLAUDE-notes/xbla.md). What it does not have is a way to tell a
// player *before* the game starts that the 227 MB file they just dropped into
// Files was recognised, what will happen to it, and roughly how long the one
// stall of their lives is going to be. On a desktop that stall is three seconds
// behind a menu the player opened on purpose; on a phone it is the first launch
// after a Files drop, and it must not look like a hang.
//
// So this file is two halves:
//
//   * a scan of Documents/xbla that mirrors the engine's own
//     (xblaDetect()/xblaScanDir(): a package by its magic, an archive by its
//     extension, either of them inside a folder, to overlay patch 0001's depth
//     of 4) and can run with no engine at all - which is what the onboarding
//     screen needs, since it runs before pdEngineMain();
//   * the unpack, driven from a background thread through the engine's own
//     xblaImportGetStfsPath(). That call blocks for the whole extraction, and
//     upstream calls it from exactly such a thread already (xblaImportWorker),
//     so this is upstream's own concurrency and not a new one. Doing it here
//     rather than leaving it to the first model load means the game thread is
//     never the one standing in the unpack, and there is a visible "preparing"
//     state instead of a frozen frame.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PDXblaKind) {
	PDXblaNone = 0,
	PDXblaArchiveRar,     // Perfect Dark.rar — the user's copy, and the common one
	PDXblaArchive7z,      // the .7z upstream's own message names
	PDXblaArchiveOther,   // .zip / .pk3 — archiveIsSupported() takes these too
	PDXblaPackage,        // the bare STFS container: LIVE / CON  / PIRS
};

@interface PDXblaFind : NSObject
@property (nonatomic) PDXblaKind kind;
@property (nonatomic, copy, nullable) NSString *path;          // absolute
@property (nonatomic, copy, nullable) NSString *relativePath;  // under added-content/ (or the legacy xbla/)
@property (nonatomic) unsigned long long bytes;
@property (nonatomic, readonly) BOOL found;
/** One line naming what was found, for a label. */
@property (nonatomic, readonly) NSString *headline;
/** What will happen to it, in words. Includes the D-011 free-space note. */
@property (nonatomic, readonly) NSString *plan;
@end

@interface PDXbla : NSObject

/**
 * The pre-engine "preparing…" note, over SDL's window.
 *
 * Public because the texture-pack unpack (PDTexPacks) needs exactly the same
 * thing for exactly the same reason, and a second window class that looked the
 * same and behaved slightly differently is how two progress screens end up
 * fighting over the same key window.
 */
+ (void)showPreparingNote:(NSString *)text;
+ (void)hidePreparingNote;

/** Documents/added-content, created if it is not there. The engine makes it too (fs.c). */
+ (NSString *)dropDir;

/** Caches/xbla — where patch 0009 routes the engine's cache/ to. */
+ (NSString *)cacheDir;

/** Scan Documents/xbla the way the engine does. No engine needed. */
+ (PDXblaFind *)scan;

/**
 * The last scan, re-run only when something could have changed.
 *
 * -scan walks Documents/xbla recursively and reads an archive header off disk,
 * and the settings page's Package row asked for one on EVERY dequeue of that
 * cell - so scrolling the page re-scanned a 250 MB drop directory once a row
 * (D-032). The result is cached and invalidated by the two things that can move
 * it: an import, and a redetect.
 */
+ (PDXblaFind *)cachedScan;

/** Forget the cached scan (an import finished, or the engine redetected). */
+ (void)invalidateScan;

/** A finished unpack: the `.extracted` marker AND a package beside it. */
+ (BOOL)isUnpacked;

/** A package the player dropped that is still inside its archive. */
+ (BOOL)needsUnpack;

/**
 * Start the one-time unpack on a background thread if one is needed, and put
 * the "preparing XBLA art…" note up while it runs. Idempotent, and a no-op
 * when there is nothing to unpack or one is already running. Game thread
 * (the frame hook) - it needs the engine up, because it is the engine's own
 * fsInit() that knows where cache/ went.
 */
+ (void)beginUnpackIfNeeded;

/**
 * The first-launch unpack, done BEFORE pdEngineMain() and with a progress
 * screen up (D-020).
 *
 * Upstream's own rule is that the game stays usable while this happens, and on
 * a desktop it does: the extraction is on the texture converter's worker
 * thread behind a menu the player opened. On iOS it is not: with Mod.XblaMeshes
 * on and a package present, the FIRST MODEL LOAD of the front end calls
 * xblaImportGetStfsPath(), which blocks - on the game thread, which is the main
 * thread, which is the one UIKit draws and pumps from. Nothing can be shown
 * while that runs, so the player gets a frozen frame and no explanation.
 *
 * So the shell gets there first. Returns when there is nothing left to unpack;
 * a no-op on every launch after the first.
 */
+ (void)runUnpackUntilReady;

@property (class, readonly) BOOL unpacking;
@property (class, readonly) NSTimeInterval unpackElapsed;
/** 0-100, from the bytes on disk against the archive's size. -1 when idle. */
@property (class, readonly) int unpackPercent;
/** Seconds the last completed unpack took, or 0. */
@property (class, readonly) NSTimeInterval lastUnpackSeconds;

/** `xbla_*` lines for the bridge's `state` (docs/remote-console.md). */
+ (NSString *)stateLines;

/**
 * A Files document picker that copies an archive or a package into
 * Documents/xbla. Presented from `vc`; `done` runs on the main thread with the
 * fresh scan, whether or not anything was picked.
 */
+ (void)presentImporterFrom:(UIViewController *)vc done:(void (^_Nullable)(PDXblaFind *))done;

@end

NS_ASSUME_NONNULL_END
