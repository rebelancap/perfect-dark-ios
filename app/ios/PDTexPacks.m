// PDTexPacks.m — see the header for why this exists at all.
#import "PDTexPacks.h"
#import "PDShell.h"
#import "PDXbla.h"

// upstream's own name for the row-order marker (port/src/texpack.c, and
// CLAUDE-notes/texture-packs.md). A folder called `ext_tex` says the same
// thing by its name and needs no file.
static NSString *const kMarkerName = @"bottomup.txt";
static NSString *const kSelfDescribingFolder = @"ext_tex";

// What archiveExtract() will take (port/src/archive.c's archiveIsSupported()).
static BOOL pdIsArchive(NSString *name)
{
	NSString *ext = name.pathExtension.lowercaseString;
	return [ext isEqualToString:@"zip"] || [ext isEqualToString:@"7z"]
	    || [ext isEqualToString:@"rar"] || [ext isEqualToString:@"pk3"];
}

@implementation PDTexPacks

+ (NSString *)dropDir
{
	NSString *dir = [PDShell.shared.documentsPath stringByAppendingPathComponent:@"texture-packs"];
	[NSFileManager.defaultManager createDirectoryAtPath:dir
	                        withIntermediateDirectories:YES attributes:nil error:NULL];
	return dir;
}

+ (NSArray<NSString *> *)entriesIn:(NSString *)dir
{
	NSArray<NSString *> *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *n in all) {
		// A dot-prefixed name is the port's own convention for "not a pack"
		// (.cache, and the in-progress download community.c writes).
		if (![n hasPrefix:@"."]) {
			[out addObject:n];
		}
	}
	return [out sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)installedPacks
{
	NSString *dir = self.dropDir;
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *n in [self entriesIn:dir]) {
		BOOL isDir = NO;
		if ([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:n]
		                                       isDirectory:&isDir] && isDir) {
			[out addObject:n];
		}
	}
	return out;
}

+ (nullable NSString *)preferredPack
{
	return self.installedPacks.firstObject;
}

/** Write the row-order marker into a pack folder that has none. */
+ (BOOL)markFolder:(NSString *)dir named:(NSString *)name
{
	if ([name.lowercaseString isEqualToString:kSelfDescribingFolder]) {
		return NO;   // the loader reads the name itself
	}
	NSString *marker = [dir stringByAppendingPathComponent:kMarkerName];
	if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
		return NO;
	}
	NSString *text =
		@"Written by Perfect Dark for iOS.\n"
		 "\n"
		 "This file tells the game the pack's images are already in N64 row\n"
		 "order (bottom row first) and must not be turned over on load. Every\n"
		 "pack built for an emulator or the VR fork is - and a pack that\n"
		 "reached this phone came from one of those, because the port's own\n"
		 "dumps are the only ones the other way up and the asset dump is not\n"
		 "available on iOS.\n"
		 "\n"
		 "If this pack draws upside down, delete this file.\n";
	NSError *err = nil;
	if (![text writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
		NSLog(@"perfectdark: [texpack] could not write %@: %@", marker, err);
		return NO;
	}
	return YES;
}

+ (NSArray<NSString *> *)prepare
{
	NSAssert(NSThread.isMainThread, @"pre-engine, UIKit's thread");

	NSString *dir = self.dropDir;
	NSMutableArray<NSString *> *log = [NSMutableArray array];

	// 1. Unpack anything new. The archive is KEPT (ground rule 5: never delete
	//    the player's files) and a dot-prefixed marker beside it records that
	//    it has been done, so the next launch is a stat rather than 180 MB.
	for (NSString *name in [self entriesIn:dir]) {
		if (!pdIsArchive(name)) {
			continue;
		}
		NSString *src = [dir stringByAppendingPathComponent:name];
		NSString *done = [dir stringByAppendingPathComponent:
			[NSString stringWithFormat:@".%@.installed", name]];
		if ([NSFileManager.defaultManager fileExistsAtPath:done]) {
			continue;
		}

		unsigned long long bytes = [[NSFileManager.defaultManager
			attributesOfItemAtPath:src error:NULL][NSFileSize] unsignedLongLongValue];
		NSLog(@"perfectdark: [texpack] unpacking %@ (%llu bytes) into %@", name, bytes, dir);
		[PDXbla showPreparingNote:[NSString stringWithFormat:@"Unpacking the texture pack\n%@", name]];

		__block BOOL ok = NO;
		__block BOOL running = YES;
		NSThread *t = [[NSThread alloc] initWithBlock:^{
			// Absolute paths go through fsFullPath() untouched (fs.c:115), so
			// this needs no fsInit() - the same property D-020 leans on.
			ok = archiveExtract(src.fileSystemRepresentation, dir.fileSystemRepresentation) > 0;
			running = NO;
		}];
		t.name = @"pd-texpack-unpack";
		t.qualityOfService = NSQualityOfServiceUserInitiated;
		[t start];

		NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
		while (running) {
			@autoreleasepool {
				[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
				                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			}
		}
		NSTimeInterval secs = NSDate.timeIntervalSinceReferenceDate - started;
		[PDXbla hidePreparingNote];

		if (ok) {
			[@"" writeToFile:done atomically:YES encoding:NSUTF8StringEncoding error:NULL];
			[log addObject:[NSString stringWithFormat:@"unpacked %@ in %.1fs", name, secs]];
		} else {
			[log addObject:[NSString stringWithFormat:@"FAILED to unpack %@", name]];
		}
		NSLog(@"perfectdark: [texpack] %@", log.lastObject);
	}

	// 2. The marker. This is the whole reason the shell is involved at all:
	//    without it every texture in the pack is upside down and nothing on
	//    disk says why (upstream's texture-packs.md).
	for (NSString *name in self.installedPacks) {
		if ([self markFolder:[dir stringByAppendingPathComponent:name] named:name]) {
			[log addObject:[NSString stringWithFormat:@"wrote %@ into %@", kMarkerName, name]];
			NSLog(@"perfectdark: [texpack] %@", log.lastObject);
		}
	}

	return log;
}

@end
