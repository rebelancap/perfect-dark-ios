// PDXbla.m — see PDXbla.h.
#import "PDXbla.h"
#import "PDVision.h"
#import "PDShell.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// --- private to this file --------------------------------------------------

@interface PDXblaPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) void (^done)(PDXblaFind *);
@end

/** The "preparing XBLA art…" note: its own window over SDL's. */
@interface PDXblaProgressWindow : NSObject
/** nil = the XBLA wording with its own percentage; anything else is shown as-is. */
+ (void)showText:(nullable NSString *)text;
+ (void)show;
+ (void)hide;
+ (BOOL)isPresented;
@end

@interface PDXblaProgressViewController : UIViewController
@end

@interface PDXbla (Private)
+ (nullable NSString *)adoptPickedURL:(NSURL *)url error:(NSError **)err;
@end

// The engine's own names, from port/src/xblaimport.c. Kept as literals rather
// than included: the shell is Foundation and the port's headers drag in
// PR/ultratypes.h and the whole decomp include path (PDShell.h's rule).
// Upstream c18645860 (fs.h FS_ADDED_CONTENT_DIR, xblaimport.c xblaDetect):
// the player's copy goes in added-content/ beside the GoldenEye ROM and the
// GoldenEye XBLA release, and the engine MOVES whatever an older install had
// in xbla/ into it the first time it looks (fs.c fsAddedContentDir). xbla/ is
// still searched after it, so the shell searches both in the same order - the
// pre-engine unpack (D-020) runs before that first move, on the folder the
// archive is still in.
static NSString *const kXblaDir    = @"added-content";
static NSString *const kLegacyDir  = @"xbla";
static NSString *const kCacheSub   = @"xbla";      // cache/xbla, patch 0009 -> Caches/xbla
static NSString *const kDoneFile   = @".extracted";
// overlay/patches/0001-xbla-import-scan-depth.patch raises XBLAIMPORT_SCAN_DEPTH
// from 2 to 4, because the user's .rar stores the package four names deep
// (Perfect Dark/584109C2/000D0000/<content id>). Scanning shallower here than
// the engine does would mean the onboarding screen saying "nothing found"
// about a copy the engine goes on to use.
static const int kScanDepth = 4;
// xblaScanForPackage()'s two "not this release" tests (D-070): added-content/
// is shared, and the engine passes over the GoldenEye XBLA archive (an entry
// under files/new/char/) and the Community Edition updater zip (gebean.h
// GEBEANCE_DIFF_ENTRY) before it takes an archive for Perfect Dark's. A .rar is
// never looked into, by the engine or here.
static NSString *const kGoldenEyeEntry = @"files/new/char/";
static NSString *const kCeUpdateEntry  = @"CEUpdate/files.diff";

static BOOL sUnpacking;
static NSTimeInterval sUnpackStarted;
static NSTimeInterval sLastUnpackSeconds;
static unsigned long long sUnpackArchiveBytes;
static NSString *sUnpackNote;            // the last thing the engine's importer said

@implementation PDXblaFind

- (BOOL)found { return self.kind != PDXblaNone; }

- (NSString *)headline
{
	if (!self.found) {
		return @"No Xbox 360 release found.";
	}
	NSString *what;
	switch (self.kind) {
	case PDXblaArchiveRar:   what = @"a RAR archive"; break;
	case PDXblaArchive7z:    what = @"a 7-Zip archive"; break;
	case PDXblaArchiveOther: what = @"an archive"; break;
	case PDXblaPackage:      what = @"the Xbox 360 package itself"; break;
	default:                 what = @"a file"; break;
	}
	return [NSString stringWithFormat:@"Found %@ — %@, %.0f MB.",
		self.relativePath ?: @"?", what, (double)self.bytes / (1024.0 * 1024.0)];
}

- (NSString *)plan
{
	if (!self.found) {
		// The Files wording, not the container path: the absolute path is right
		// and unusable - it is forty characters of UUID and a player on a phone
		// has no way to navigate to it. The ROM line above names the same folder
		// the same way.
		return @"Optional: the Xbox 360 (XBLA) release. Put Perfect Dark.rar, a .7z, the bare "
		        "Xbox 360 package, or a folder holding one, into the added-content folder here:\n"
		        "    Files → On My iPhone → Perfect Dark → added-content\n"
		        "Then the game draws 4J's high-resolution textures, meshes, rooms, font and "
		        "explosions in place of the N64 art.";
	}
	if (self.kind == PDXblaPackage) {
		return @"That is the package itself, so nothing has to be unpacked — the game reads it "
		        "where it is. The Xbox 360 art will be on the first time you play.";
	}
	if (PDXbla.isUnpacked) {
		return @"Already unpacked — the Xbox 360 art is ready.";
	}
	// "A few seconds" is measured, not guessed: 1.7 s on the lane-3 simulator
	// (M-013). The release's archive is barely compressed, so this is close to
	// a 250 MB file copy and a phone's flash decides it.
	return @"The first launch after this unpacks it once, into the app's Caches folder: about "
	        "250 MB written, usually a few seconds. Keep about 500 MB free. Your own file is "
	        "never touched, and if the system ever reclaims the Caches folder the app quietly "
	        "unpacks it again.";
}

@end

// ---------------------------------------------------------------------------

@implementation PDXbla

+ (NSString *)dropDir
{
	NSString *dir = [PDShell.shared.documentsPath stringByAppendingPathComponent:kXblaDir];
	if (![NSFileManager.defaultManager fileExistsAtPath:dir]) {
		[NSFileManager.defaultManager createDirectoryAtPath:dir
		                        withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	return dir;
}

+ (NSString *)cacheDir
{
	return [[PDShell.shared.cachesPath stringByAppendingPathComponent:@"cache"]
		stringByAppendingPathComponent:kCacheSub];
}

/** The engine's xblaLooksLikePackage(): STFS magic, nothing else. */
+ (BOOL)looksLikePackage:(NSString *)path
{
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!fh) {
		return NO;
	}
	NSData *magic = [fh readDataOfLength:4];
	[fh closeFile];
	if (magic.length != 4) {
		return NO;
	}
	const char *m = magic.bytes;
	return !memcmp(m, "LIVE", 4) || !memcmp(m, "CON ", 4) || !memcmp(m, "PIRS", 4);
}

/** The engine's archiveIsSupported(): the extension, nothing else. */
+ (PDXblaKind)archiveKind:(NSString *)path
{
	NSString *ext = path.pathExtension.lowercaseString;
	if ([ext isEqualToString:@"rar"]) { return PDXblaArchiveRar; }
	if ([ext isEqualToString:@"7z"])  { return PDXblaArchive7z; }
	if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"pk3"]) { return PDXblaArchiveOther; }
	return PDXblaNone;
}

/** An archive the engine's scan passes over because it is another release's. */
+ (BOOL)isOtherRelease:(NSString *)path
{
	const char *p = path.fileSystemRepresentation;
	return archiveFindEntry(p, kGoldenEyeEntry.UTF8String)
	    || archiveFindEntry(p, kCeUpdateEntry.UTF8String);
}

/**
 * One pass of the engine's xblaScanDir(). `archives` NO is the package pass and
 * YES the archive pass, and the engine runs them in that order for the reason
 * its comment gives: a player who has both has already paid for the extraction.
 */
+ (nullable NSString *)scanDir:(NSString *)dir archives:(BOOL)archives depth:(int)depth
{
	NSArray<NSString *> *names =
		[[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
			sortedArrayUsingSelector:@selector(compare:)];
	NSMutableArray<NSString *> *subdirs = [NSMutableArray array];

	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;               // the engine skips dotfiles, .extracted included
		}
		NSString *path = [dir stringByAppendingPathComponent:name];
		BOOL isDir = NO;
		if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) {
			continue;
		}
		if (isDir) {
			[subdirs addObject:path];
			continue;
		}
		if ([self looksLikePackage:path]) {
			return path;
		}
		if (archives && [self archiveKind:path] != PDXblaNone && ![self isOtherRelease:path]) {
			return path;
		}
	}

	if (depth > 0) {
		for (NSString *sub in subdirs) {
			NSString *hit = [self scanDir:sub archives:archives depth:depth - 1];
			if (hit) {
				return hit;
			}
		}
	}
	return nil;
}

+ (PDXblaFind *)scan
{
	PDXblaFind *f = [PDXblaFind new];
	NSString *root = nil;
	NSString *hit = nil;
	NSString *legacy = [PDShell.shared.documentsPath stringByAppendingPathComponent:kLegacyDir];

	// The engine's order (xblaDetect): added-content/ first, xbla/ after it,
	// a package before an archive within each. xbla/ is looked in, never made.
	for (NSString *dir in @[ self.dropDir, legacy ]) {
		hit = [self scanDir:dir archives:NO depth:kScanDepth]
		   ?: [self scanDir:dir archives:YES depth:kScanDepth];
		if (hit) {
			root = dir;
			break;
		}
	}
	if (!hit) {
		return f;
	}

	f.path = hit;
	f.relativePath = [hit hasPrefix:root] ? [hit substringFromIndex:root.length + 1] : hit.lastPathComponent;
	f.bytes = [NSFileManager.defaultManager attributesOfItemAtPath:hit error:NULL].fileSize;
	f.kind = [self looksLikePackage:hit] ? PDXblaPackage : [self archiveKind:hit];
	return f;
}

static PDXblaFind *sCachedScan;

+ (PDXblaFind *)cachedScan
{
	// The engine's first look moves xbla/* into added-content/ (fs.c
	// fsAddedContentDir) after the shell's pre-engine scan, so a cached find can
	// name a path that is no longer there. Gone = look again.
	if (sCachedScan.found && ![NSFileManager.defaultManager fileExistsAtPath:sCachedScan.path]) {
		sCachedScan = nil;
	}
	if (!sCachedScan) {
		sCachedScan = self.scan;
		NSLog(@"perfectdark: [xbla] scan cached: %@", sCachedScan.headline);
	}
	return sCachedScan;
}

+ (void)invalidateScan { sCachedScan = nil; }

+ (BOOL)isUnpacked
{
	NSString *dir = self.cacheDir;
	NSString *marker = [dir stringByAppendingPathComponent:kDoneFile];
	if (![NSFileManager.defaultManager fileExistsAtPath:marker]) {
		return NO;
	}
	// The marker alone is not the answer: xblaFindExtractedIn() wants a package
	// under it as well, and a half-written cache that kept its marker would
	// otherwise read as ready.
	return [self scanDir:dir archives:NO depth:kScanDepth] != nil;
}

+ (BOOL)needsUnpack
{
	PDXblaFind *f = self.scan;
	return f.found && f.kind != PDXblaPackage && !self.isUnpacked;
}

+ (BOOL)unpacking { return sUnpacking; }
+ (NSTimeInterval)unpackElapsed
{
	return sUnpacking ? (NSDate.timeIntervalSinceReferenceDate - sUnpackStarted) : 0;
}
+ (NSTimeInterval)lastUnpackSeconds { return sLastUnpackSeconds; }

/**
 * Bytes on disk under Caches/xbla against the archive's own size.
 *
 * archiveExtract() has no progress callback, so this is measured rather than
 * reported. The release's archive barely compresses (upstream: "already
 * compressed data"), so the two sizes are within a few percent of each other
 * and the number is honest enough to watch a bar move by. Clamped at 99 so it
 * never claims to be finished before the marker is written.
 */
+ (int)unpackPercent
{
	if (!sUnpacking || !sUnpackArchiveBytes) {
		return -1;
	}
	unsigned long long total = 0;
	NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:self.cacheDir];
	for (NSString *rel in e) {
		total += e.fileAttributes.fileSize;
	}
	int pct = (int)((100.0 * (double)total) / (double)sUnpackArchiveBytes);
	return pct < 0 ? 0 : (pct > 99 ? 99 : pct);
}

+ (void)beginUnpackIfNeeded
{
	// Asked once a frame, so the answer is decided once. Upstream paid for
	// exactly this lesson on its own side (xblaimport.c: 57 opens of a 233 MB
	// archive and 110 directory probes over one level load, all of them
	// re-deciding what the first one decided).
	static BOOL decided;

	if (decided || sUnpacking || !PDShell.shared.engineRunning) {
		return;
	}
	decided = YES;

	PDXblaFind *f = self.scan;
	if (!f.found || f.kind == PDXblaPackage) {
		return;
	}
	if (self.isUnpacked) {
		return;
	}

	sUnpacking = YES;
	sUnpackStarted = NSDate.timeIntervalSinceReferenceDate;
	sUnpackArchiveBytes = f.bytes;
	sUnpackNote = @"unpacking";
	NSLog(@"perfectdark: [xbla] unpacking %@ (%llu bytes) into %@",
		f.relativePath, f.bytes, self.cacheDir);

	[PDXblaProgressWindow show];

	// Upstream's own worker thread calls exactly this function for exactly this
	// reason (xblaimport.c, xblaImportWorker) - the unpack is mutex-guarded and
	// fsFullPath()'s scratch buffer is _Thread_local, so a second thread in
	// there is the designed case. What it buys us is that the GAME thread is
	// never the one waiting: the frame loop keeps turning, the progress note
	// keeps drawing, and the model loader finds the package already there.
	NSThread *t = [[NSThread alloc] initWithBlock:^{
		const char *path = xblaImportGetStfsPath();
		NSTimeInterval took = NSDate.timeIntervalSinceReferenceDate - sUnpackStarted;

		if (path && *path) {
			NSLog(@"perfectdark: [xbla] unpacked in %.1fs -> %s", took, path);
			sUnpackNote = @"ready";
		} else {
			NSLog(@"perfectdark: [xbla] unpack FAILED after %.1fs", took);
			sUnpackNote = @"failed";
		}
		sLastUnpackSeconds = took;
		sUnpacking = NO;

		// The importer decided there was no package while the archive was still
		// an archive; now there is one, so let it look again.
		[PDShell.shared enqueue:^{ xblaImportRedetect(); }];
		dispatch_async(dispatch_get_main_queue(), ^{ [PDXblaProgressWindow hide]; });
	}];
	t.name = @"pd-xbla-unpack";
	t.qualityOfService = NSQualityOfServiceUserInitiated;
	[t start];
}

/**
 * The unpack the shell does itself, before the engine exists. See the header
 * for why it is not left to the engine (D-020).
 *
 * The layout written here is exactly the one xblaEnsureUnpackedLocked() expects
 * to find on the next launch - the archive's contents under Caches/cache/xbla
 * and a `.extracted` marker beside them - so the engine's own path is a scan
 * and a stat, and nothing is unpacked twice.
 */
+ (void)showPreparingNote:(NSString *)text
{
	[PDXblaProgressWindow showText:text];
	// The note is a UIKit view and nothing else is turning the run loop yet;
	// one pass gets it on screen before the caller starts blocking.
	[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
	                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

+ (void)hidePreparingNote
{
	[PDXblaProgressWindow hide];
}

+ (void)runUnpackUntilReady
{
	NSAssert(NSThread.isMainThread, @"pre-engine, UIKit's thread");

	PDXblaFind *f = self.scan;
	if (!f.found || f.kind == PDXblaPackage || self.isUnpacked) {
		if (f.found) {
			NSLog(@"perfectdark: [xbla] %@ — nothing to unpack", f.headline);
		}
		return;
	}

	NSString *dir = self.cacheDir;
	[NSFileManager.defaultManager createDirectoryAtPath:dir
	                        withIntermediateDirectories:YES attributes:nil error:NULL];

	// A cache that has files in it but no marker is a previous attempt that was
	// killed (the app swiped away mid-unpack, or the gate's terminate). Start
	// clean rather than extracting over the top of half a package.
	NSArray *leftovers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL];
	if (leftovers.count) {
		NSLog(@"perfectdark: [xbla] clearing %lu leftovers from an unfinished unpack",
			(unsigned long)leftovers.count);
		[NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
		[NSFileManager.defaultManager createDirectoryAtPath:dir
		                        withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	sUnpacking = YES;
	sUnpackStarted = NSDate.timeIntervalSinceReferenceDate;
	sUnpackArchiveBytes = f.bytes;
	sUnpackNote = @"unpacking";
	NSLog(@"perfectdark: [xbla] pre-engine unpack of %@ (%llu bytes) -> %@",
		f.relativePath, f.bytes, dir);

	[PDXblaProgressWindow show];

	__block BOOL ok = NO;
	NSString *src = f.path;
	NSThread *t = [[NSThread alloc] initWithBlock:^{
		// archive.c takes absolute paths straight through fsFullPath(), so this
		// works with no fsInit() behind it (PDShell.h).
		ok = archiveExtract(src.fileSystemRepresentation, dir.fileSystemRepresentation) > 0;
		sUnpacking = NO;
	}];
	t.name = @"pd-xbla-unpack";
	t.qualityOfService = NSQualityOfServiceUserInitiated;
	[t start];

	// The engine is not running, so nothing else is pumping the run loop - the
	// same shape as PDOnboarding's wait, and for the same reason.
	while (sUnpacking) {
		@autoreleasepool {
			[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
			                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
	}

	sLastUnpackSeconds = NSDate.timeIntervalSinceReferenceDate - sUnpackStarted;

	if (ok && [self scanDir:dir archives:NO depth:kScanDepth]) {
		// The marker is what says "finished" to both sides. Written only after
		// a package has actually been found under it, so a truncated archive
		// cannot leave a cache that reads as ready for ever.
		[NSFileManager.defaultManager createFileAtPath:[dir stringByAppendingPathComponent:kDoneFile]
		                                      contents:[NSData data] attributes:nil];
		sUnpackNote = @"ready";
		NSLog(@"perfectdark: [xbla] unpacked in %.1fs", sLastUnpackSeconds);
	} else {
		sUnpackNote = @"failed";
		NSLog(@"perfectdark: [xbla] unpack FAILED after %.1fs (archiveExtract %@, package %@)",
			sLastUnpackSeconds, ok ? @"ok" : @"failed",
			[self scanDir:dir archives:NO depth:kScanDepth] ?: @"not found");
	}

	[PDXblaProgressWindow hide];
}

+ (NSString *)stateLines
{
	PDXblaFind *f = self.scan;
	NSMutableString *s = [NSMutableString string];
	[s appendFormat:@"xbla_found=%d\n", (int)f.found];
	[s appendFormat:@"xbla_kind=%@\n", f.found ? (f.kind == PDXblaPackage ? @"package" : @"archive") : @"none"];
	[s appendFormat:@"xbla_file=%@\n", f.relativePath ?: @"-"];
	[s appendFormat:@"xbla_extracted=%d\n", (int)self.isUnpacked];
	[s appendFormat:@"xbla_unpacking=%d\n", (int)sUnpacking];
	[s appendFormat:@"xbla_unpack_pct=%d\n", self.unpackPercent];
	[s appendFormat:@"xbla_unpack_secs=%.1f\n", sLastUnpackSeconds];
	[s appendFormat:@"xbla_cache=%@\n", self.cacheDir];
	[s appendFormat:@"xbla_note=%@\n", sUnpackNote ?: @"-"];
	return s;
}

// --- the Files importer ----------------------------------------------------

+ (void)presentImporterFrom:(UIViewController *)vc done:(void (^)(PDXblaFind *))done
{
	static PDXblaPickerDelegate *keep;   // the picker does not retain its delegate
	keep = [PDXblaPickerDelegate new];
	keep.done = done;

	// Anything at all: the release travels as .rar, .7z, .zip and as a bare
	// package with a 40-hex-character name and no extension whatsoever, and a
	// picker that filters on type would hide the last of those completely.
	UIDocumentPickerViewController *p =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
	p.delegate = keep;
	p.allowsMultipleSelection = NO;
	[vc presentViewController:p animated:YES completion:nil];
	NSLog(@"perfectdark: [xbla] presenting the document picker");
}

/** Copy a picked file into Documents/added-content. Main thread; returns the new path. */
+ (nullable NSString *)adoptPickedURL:(NSURL *)url error:(NSError **)err
{
	NSString *dst = [self.dropDir stringByAppendingPathComponent:url.lastPathComponent];
	[NSFileManager.defaultManager removeItemAtPath:dst error:NULL];
	if (![NSFileManager.defaultManager copyItemAtPath:url.path toPath:dst error:err]) {
		return nil;
	}
	// Same reason as the ROM (PDOnboarding): the engine opens this with plain
	// fopen(), and an app can be launched while the device is still locked after
	// a reboot. Data protection would make that open fail with EPERM and look
	// exactly like a missing file.
	[NSFileManager.defaultManager setAttributes:@{ NSFileProtectionKey: NSFileProtectionNone }
	                               ofItemAtPath:dst error:NULL];
	return dst;
}

@end

// ---------------------------------------------------------------------------

@implementation PDXblaPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
	didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSURL *url = urls.firstObject;
	if (url) {
		BOOL scoped = [url startAccessingSecurityScopedResource];
		NSError *err = nil;
		NSString *dst = [PDXbla adoptPickedURL:url error:&err];
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		NSLog(@"perfectdark: [xbla] imported %@ -> %@ (%@)",
			url.lastPathComponent, dst ?: @"FAILED", err ?: @"ok");
	}
	if (self.done) {
		[PDXbla invalidateScan];
		self.done(PDXbla.scan);
	}
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	if (self.done) {
		[PDXbla invalidateScan];
		self.done(PDXbla.scan);
	}
}

@end

// ---------------------------------------------------------------------------

// "Preparing XBLA art…" — a window of its own over SDL's, the same shape the
// settings page uses and for the same reason (SDL owns the game window's root
// view controller and fights anything presented over it for orientation).
@implementation PDXblaProgressWindow

static UIWindow *sProgressWindow;
static UILabel *sProgressLabel;
static UIProgressView *sProgressBar;
static NSTimer *sProgressTimer;

static NSString *sProgressFixedText;

+ (void)show { [self showText:nil]; }

+ (void)showText:(NSString *)text
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self showText:text]; });
		return;
	}
	sProgressFixedText = [text copy];
	if (sProgressWindow) {
		return;
	}

	UIViewController *vc = [PDXblaProgressViewController new];
	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class]) {
			scene = (UIWindowScene *)s;
			break;
		}
	}
	sProgressWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
	                        : [[UIWindow alloc] initWithFrame:PDVisionFallbackWindowFrame()];
	sProgressWindow.windowLevel = UIWindowLevelAlert;
	sProgressWindow.rootViewController = vc;
	sProgressWindow.backgroundColor = UIColor.clearColor;
	[sProgressWindow makeKeyAndVisible];

	sProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
		if (sProgressFixedText) {
			sProgressLabel.text = sProgressFixedText;
			sProgressBar.hidden = YES;
			return;
		}
		sProgressBar.hidden = NO;
		int pct = PDXbla.unpackPercent;
		int secs = (int)lround(PDXbla.unpackElapsed);
		sProgressLabel.text = [NSString stringWithFormat:
			@"Preparing the Xbox 360 art — %d%%\n%d second%s so far. This happens once.",
			pct < 0 ? 0 : pct, secs, secs == 1 ? "" : "s"];
		sProgressBar.progress = (pct < 0 ? 0 : pct) / 100.0f;
	}];
	NSLog(@"perfectdark: [xbla] progress note up");
}

+ (void)hide
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; });
		return;
	}
	[sProgressTimer invalidate];
	sProgressTimer = nil;
	sProgressFixedText = nil;
	sProgressWindow.hidden = YES;
	sProgressWindow = nil;
	sProgressLabel = nil;
	sProgressBar = nil;
	NSLog(@"perfectdark: [xbla] progress note down");
}

+ (BOOL)isPresented { return sProgressWindow != nil && !sProgressWindow.hidden; }

@end

@implementation PDXblaProgressViewController

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad
{
	[super viewDidLoad];
	// The engine has not started yet, so there is nothing behind this: opaque,
	// and the same near-black the onboarding screen uses.
	self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0];

	UILabel *title = [UILabel new];
	title.text = @"Xbox 360 release";
	title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
	title.textColor = UIColor.whiteColor;
	title.textAlignment = NSTextAlignmentCenter;

	sProgressLabel = [UILabel new];
	sProgressLabel.numberOfLines = 0;
	sProgressLabel.textAlignment = NSTextAlignmentCenter;
	sProgressLabel.font = [UIFont systemFontOfSize:15];
	sProgressLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
	sProgressLabel.text = @"Preparing the Xbox 360 art — 0%\nThis happens once.";

	sProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

	UILabel *foot = [UILabel new];
	foot.numberOfLines = 0;
	foot.textAlignment = NSTextAlignmentCenter;
	foot.font = [UIFont systemFontOfSize:13];
	foot.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
	// Honest: the game has not started yet. This runs before pdEngineMain()
	// precisely so that the alternative - a frozen drawn frame - cannot happen
	// (D-020), which means there is nothing behind this to keep playing.
	foot.text = @"The game starts as soon as this finishes. Your own copy of the release is "
	             "not touched.";

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
		@[ title, sProgressLabel, sProgressBar, foot ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 12;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:60],
		[stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-60],
		[stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
	]];
}

@end
