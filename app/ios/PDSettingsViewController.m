// PDSettingsViewController.m — a plain UITableView over the game.
//
// Why native and not the game's own options pages: Perfect Dark's menus are
// pad/keyboard driven and sit at N64 scale; the settings a phone player needs
// most (look sensitivity, button size, the XBLA switch) are either not in them
// at all or three levels down. The game's pages stay exactly as they are - this
// is in addition to them, not instead.
//
// The page is spec-driven: one row descriptor per setting, so adding a row is
// one line and no new code path. NSUserDefaults is written immediately (a
// setting that does not survive being swiped away is the family's oldest bug)
// and pushed into the live engine through PDShell's frame-boundary queue.
#import "PDSettingsViewController.h"
#import "PDVision.h"
#import "PDShell.h"
#import "PDDefaults.h"
#import "PDPacing.h"
#import "PDTouchOverlay.h"
#import "PDXbla.h"
#import "PDAudio.h"
#import "PDWatchdog.h"

#include "build_stamp.h"

#import <objc/runtime.h>

// app/gfx/gfx_angle_egl.mm — the SDL_MetalView the renderer draws into; its
// -window is the game's window, which is the one that has to be key whenever
// this page is not up (D-041).
extern void *pdAngleGetHostView(void);

typedef NS_ENUM(NSInteger, PDRowKind) {
	PDRowSwitch,
	PDRowSlider,
	PDRowSegmented,
	PDRowInfo,
	PDRowButton,
};

@interface PDRow : NSObject
@property (nonatomic) PDRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic) float min, max;
@property (nonatomic, copy, nullable) NSArray<NSString *> *choices;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *values;
@property (nonatomic, copy, nullable) NSString *(^info)(void);
@property (nonatomic, copy, nullable) void (^action)(void);
// A slider whose value is a whole number with a unit after it ("40 %"), rather
// than the default two decimal places a sensitivity wants.
@property (nonatomic, copy, nullable) NSString *unit;
// A 0…1 slider shown and stored as a percentage ("80%"). Volume is the only
// one, and it is a multiplier everywhere else in the app - the engine reads it
// as a gain - so the percentage is presentation, not storage.
@property (nonatomic) BOOL percent;
@end
@implementation PDRow @end

/** The value label beside a slider, in the form that row asked for. */
static NSString *pdSliderText(PDRow *row, float v)
{
	if (row.percent) {
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	}
	return row.unit ? [NSString stringWithFormat:@"%.0f%@", v, row.unit]
	                : [NSString stringWithFormat:@"%.2f", v];
}

static PDRow *pdSwitchRow(NSString *title, NSString *key)
{
	PDRow *r = [PDRow new]; r.kind = PDRowSwitch; r.title = title; r.key = key; return r;
}
static PDRow *pdSliderRow(NSString *title, NSString *key, float lo, float hi)
{
	PDRow *r = [PDRow new]; r.kind = PDRowSlider; r.title = title; r.key = key; r.min = lo; r.max = hi; return r;
}
static PDRow *pdSegRow(NSString *title, NSString *key, NSArray<NSString *> *choices, NSArray<NSNumber *> *values)
{
	PDRow *r = [PDRow new]; r.kind = PDRowSegmented; r.title = title; r.key = key;
	r.choices = choices; r.values = values; return r;
}
static PDRow *pdInfoRow(NSString *title, NSString *(^info)(void))
{
	PDRow *r = [PDRow new]; r.kind = PDRowInfo; r.title = title; r.info = info; return r;
}
static PDRow *pdButtonRow(NSString *title, void (^action)(void))
{
	PDRow *r = [PDRow new]; r.kind = PDRowButton; r.title = title; r.action = action; return r;
}
static PDRow *pdPercentSliderRow(NSString *title, NSString *key)
{
	PDRow *r = pdSliderRow(title, key, 0.0f, 1.0f); r.percent = YES; return r;
}
/**
 * The Frame rate row, built from the PANEL rather than from a constant (D-056).
 *
 * `PDPanelHighHz()` is the high segment: 120 on a ProMotion phone, 90 on this
 * Vision Pro, 60 on a 60 Hz phone — and at 60 there is exactly one segment,
 * because a row whose two choices are the same rate is a row that lies.
 *
 * D-044's `hide60on120` insurance is unchanged and still only arms on a panel
 * above 60: with it set, the low segment goes away entirely and the player keeps
 * the panel's rate, which is the rate that works on the user's phone.
 */
static PDRow *pdFrameRateRow(void)
{
	const NSInteger high = PDPanelHighHz();
	NSString *highLabel = [NSString stringWithFormat:@"%ld Hz", (long)high];
	if (high <= 60) {
		return pdSegRow(@"Frame rate", PDDefRefreshHz, @[ @"60 Hz" ], @[ @60 ]);
	}
	if (PDDefBool(PDDefHide60On120)) {
		return pdSegRow(@"Frame rate", PDDefRefreshHz, @[ highLabel ], @[ @(high) ]);
	}
	return pdSegRow(@"Frame rate", PDDefRefreshHz, @[ @"60 Hz", highLabel ], @[ @60, @(high) ]);
}
/** bean's shape: a row that shows the current choice and opens a picker. */
static PDRow *pdChoiceRow(NSString *title, NSString *(^info)(void), void (^action)(void))
{
	PDRow *r = [PDRow new]; r.kind = PDRowButton; r.title = title;
	r.info = info; r.action = action; return r;
}

// ---------------------------------------------------------------------------

/**
 * "Other App Audio" — the five-mode picker, bean's exactly (settings_uikit.mm
 * RexAudioModeController).
 *
 * A form sheet with one subtitle cell per mode: the name, and one sentence
 * saying what it does to the player's music. Picking one writes the default,
 * re-applies the session, shows the checkmark, and backs out after a beat so
 * the choice is visibly taken (D-033).
 */
@interface PDAudioModeViewController : UITableViewController
@property (nonatomic, copy, nullable) void (^onPick)(void);
@end

@implementation PDAudioModeViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Other App Audio";
	self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
	self.tableView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		                                              target:self action:@selector(dismissSelf)];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
	return (NSInteger)PDAudio.modeTitles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
	                                            reuseIdentifier:nil];
	c.textLabel.text = PDAudio.modeTitles[(NSUInteger)ip.row];
	c.detailTextLabel.text = PDAudio.modeDetails[(NSUInteger)ip.row];
	// Let the explanation wrap rather than truncate: it is the whole point of
	// the sheet, and "Lower Game Audio" means nothing on its own.
	c.detailTextLabel.numberOfLines = 0;
	c.detailTextLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
	c.accessoryType = (ip.row == PDDefInt(PDDefAudioSessionMode))
		? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
	[tv deselectRowAtIndexPath:ip animated:YES];
	[NSUserDefaults.standardUserDefaults setInteger:ip.row forKey:PDDefAudioSessionMode];
	[PDAudio settingsChanged];
	[tv reloadData];
	if (self.onPick) {
		self.onPick();
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ [self dismissSelf]; });
}

@end

// ---------------------------------------------------------------------------

static UIWindow *sWindow;
/** When the gear was tapped, so viewDidAppear can say how long the page took. */
static CFTimeInterval sPresentStarted;

// Forward declarations: +present and +prewarm both reach these before the file
// gets round to defining them.
@interface PDSettingsViewController ()
+ (void)build;
- (void)buildRows;
- (void)segChanged:(UISegmentedControl *)seg;
+ (void)logOpenLatency;
+ (nullable PDSettingsViewController *)presentedControllerEvenIfHidden;
@end

@implementation PDSettingsViewController {
	NSArray<NSString *> *_sections;
	NSArray<NSArray<PDRow *> *> *_rows;
}

+ (BOOL)isPresented { return sWindow != nil && !sWindow.hidden; }

+ (void)present
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self present]; });
		return;
	}
	sPresentStarted = CACurrentMediaTime();
	const BOOL reused = (sWindow != nil);
	if (reused) {
		// The cheap path, and since round R it is the path EVERY open takes -
		// the shell prewarms the page at frame 600 (D-041, BUG 4). The window,
		// the navigation controller, the table and its forty-odd cells are all
		// still there; only the values can have moved underneath them.
		[[self presentedControllerEvenIfHidden].tableView reloadData];
	} else {
		[self build];
	}
	sWindow.hidden = NO;
	[sWindow makeKeyAndVisible];
	PDLifecycle("settings PRESENT (%s)", reused ? "reused" : "built here");
	NSLog(@"perfectdark: [settings] presented %@ frame=%@",
		reused ? @"(reused)" : @"(built here)", NSStringFromCGRect(sWindow.frame));
	[self logOpenLatency];
}

/**
 * How long the page took from the gear to being laid out and on screen.
 *
 * -viewDidAppear: answers this on the FIRST open and cannot answer it again:
 * since round R the controller is kept across a dismiss, so the second open
 * unhides a window whose view has already appeared. The run loop coming back
 * round is the honest end point either way - by then UIKit has laid the page
 * out and committed the transaction.
 */
+ (void)logOpenLatency
{
	if (sPresentStarted <= 0) {
		return;
	}
	const CFTimeInterval t0 = sPresentStarted;
	sPresentStarted = 0;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSLog(@"perfectdark: [settings] open latency %.0f ms", (CACurrentMediaTime() - t0) * 1000.0);
	});
}

/**
 * Build the window, the navigation controller, the table and its cells —
 * WITHOUT showing any of it. Main thread; does nothing if it already exists.
 *
 * Split out of +present for +prewarm (BUG 4): the first open pays for ~40
 * cells, their SF Symbols, their switches and segmented controls, and it pays
 * on the GAME thread, which is the main thread here — so the frame that opens
 * the page is the frame that builds the whole table, and that is the hitch
 * the user feels the first time he reaches for the gear.
 */
+ (void)build
{
	if (sWindow) {
		return;
	}
	PDSettingsViewController *vc = [[PDSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];

	// Its own window: SDL owns the root view controller of the game's window,
	// and presenting over it fights SDL's own view controller for orientation.
	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) {
			scene = (UIWindowScene *)s;
			break;
		}
	}
	sWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
	                : [[UIWindow alloc] initWithFrame:PDVisionFallbackWindowFrame()];
	sWindow.windowLevel = UIWindowLevelAlert;
	sWindow.rootViewController = nav;
	sWindow.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	sWindow.hidden = YES;
	NSLog(@"perfectdark: [settings] built frame=%@ scene=%@",
		NSStringFromCGRect(sWindow.frame), scene ? @"yes" : @"no");
}

/**
 * Build the page now, off the critical path, so the first gear tap is as cheap
 * as the second (BUG 4). Called once from the shell a second or so after the
 * engine is up, when nothing is waiting on the frame.
 */
+ (void)prewarm
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self prewarm]; });
		return;
	}
	if (sWindow) {
		return;
	}
	const CFTimeInterval t0 = CACurrentMediaTime();
	[self build];
	// Force the table through its first layout and cell construction, which is
	// the expensive half and the half a hidden window would otherwise defer to
	// the moment it is shown.
	UINavigationController *nav = (UINavigationController *)sWindow.rootViewController;
	[nav.view layoutIfNeeded];
	PDSettingsViewController *vc = [self presentedControllerEvenIfHidden];
	[vc.tableView layoutIfNeeded];
	NSLog(@"perfectdark: [settings] prewarmed in %.0f ms",
		(CACurrentMediaTime() - t0) * 1000.0);
}

/**
 * Hide it, and hand the key window back to the game (D-041).
 *
 * THE ORDER MATTERS, and the two things it does are the round-R fix.
 *
 * What this used to be was `sWindow.hidden = YES; sWindow = nil;` — which
 * hides the app's KEY window and then deallocates it, leaving the scene with
 * no key window at all and nothing promoted in its place. On the simulator
 * UIKit puts SDL's window back by itself and every scripted open/close came
 * back with `route_ok=1`; on the user's phone it did not, and what he got was a
 * game still rendering (the CAMetalLayer presents its own drawables and needs
 * nobody's permission) under a FROZEN UIKit layer tree — the chips as they were
 * the moment the page went up — that no longer took a touch. Force-quit was the
 * only way out, and `settings`/`settings close` over the bridge could not undo
 * it because they run the same two lines.
 *
 * So: the game's window is made key and visible FIRST, while the settings
 * window is still alive, and the settings window is then hidden and KEPT
 * (nothing is deallocated while it is key, and the next open is the cheap
 * path — see +present). Then the touch layer re-asserts, which now includes
 * the routed hit test, and the window is marked for layout so a UIKit layer
 * tree that stopped being composited under the page is redrawn.
 */
+ (void)dismiss
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
		return;
	}
	if (!sWindow) {
		return;
	}
	UIWindow *game = ((__bridge UIView *)pdAngleGetHostView()).window;
	if (game) {
		[game makeKeyAndVisible];
	}
	sWindow.hidden = YES;
	// sWindow is deliberately NOT released: see above, and it is what makes the
	// second open cost nothing.
	PDLifecycle("settings DISMISS (key -> %s, deferred pacing=%d)",
		game ? "game window" : "NOTHING", (int)PDDefaultsPacingIsDeferred());
	NSLog(@"perfectdark: [settings] dismissed (key -> %@)", game ? @"game window" : @"NOTHING");

	PDTouchOverlay *v = PDTouchOverlay.current;
	[v reassertTouchability];
	// The layers under an opaque full-screen window may not have been
	// composited while it was up. Ask for all of it back.
	[game setNeedsLayout];
	for (UIView *sub in game.subviews) {
		[sub setNeedsDisplay];
		[sub setNeedsLayout];
	}
	[v setNeedsLayout];

	// The panel rate the page asked for, if it had to wait (D-041 round 2).
	// One turn of the run loop after the window is down, then at a frame
	// boundary on the game thread - so nothing re-paces the main thread while
	// UIKit still has a transition of its own to finish.
	if (PDDefaultsPacingIsDeferred()) {
		dispatch_async(dispatch_get_main_queue(), ^{
			PDLifecycle("settings: deferred panel rate — queued on the frame hook");
			[PDShell.shared enqueue:^{
				PDLifecycle("settings: deferred panel rate — running on the frame hook");
				NSLog(@"perfectdark: [settings] applying the deferred panel rate");
				PDDefaultsApplyToEngine();
				configSave("$S/pd.ini");
			}];
		});
	}
}

+ (void)destroy
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self destroy]; });
		return;
	}
	[self dismiss];
	sWindow.rootViewController = nil;
	sWindow.windowScene = nil;
	sWindow = nil;
	NSLog(@"perfectdark: [settings] window destroyed (heal experiment)");
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	// Opaque and dark, deliberately, and never a blur (bean, settings_uikit.mm:
	// 559-567): a system blur is a backdrop filter over a CAMetalLayer that is
	// still redrawing, so the compositor re-blurs the whole screen every frame
	// on a GPU that is already busy. An opaque background also lets UIKit stop
	// compositing the game layer entirely while the page is up.
	self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
	self.view.opaque = YES;
	self.tableView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
	self.tableView.opaque = YES;
	self.title = @"Perfect Dark";
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		                                              target:self action:@selector(done)];
	[self buildRows];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	// The latency is reported by +logOpenLatency now, which works on every open
	// and not only the first (the controller outlives a dismiss since round R).
}

- (void)done { [PDSettingsViewController dismiss]; }

/** The page's own table, or nil when it is not up. Main thread. */
+ (nullable PDSettingsViewController *)presentedController
{
	// Since round R the controller outlives a dismiss (D-041), so "it exists"
	// is no longer the same question as "it is on screen" — and `settings row`
	// pressing a row on a page nobody can see is not a check of anything.
	return sWindow.hidden ? nil : [self presentedControllerEvenIfHidden];
}

+ (nullable PDSettingsViewController *)presentedControllerEvenIfHidden
{
	UINavigationController *nav = (UINavigationController *)sWindow.rootViewController;
	if (![nav isKindOfClass:UINavigationController.class]) {
		return nil;
	}
	UIViewController *vc = nav.viewControllers.firstObject;
	return [vc isKindOfClass:PDSettingsViewController.class] ? (PDSettingsViewController *)vc : nil;
}

/**
 * Move a SEGMENTED row to segment `seg`, exactly as a finger on that segment
 * would: the control's own selectedSegmentIndex, then -segChanged: (D-041
 * round 2).
 *
 * `settings row` presses a row through -didSelectRowAtIndexPath:, which a
 * segmented row ignores - it has no action, its control does. So until this
 * existed there was NO scripted path through the Frame rate row, which is the
 * exact row the user's touch dies on, and "reproduce it on the simulator" could
 * not even be attempted honestly. Returns what it moved, or nil.
 */
+ (NSString *)setSegmentInSection:(NSString *)needle atIndex:(NSInteger)index to:(NSInteger)seg
{
	NSCAssert(NSThread.isMainThread, @"UIKit");
	PDSettingsViewController *vc = [self presentedController];
	if (!vc) {
		return nil;
	}
	for (NSUInteger i = 0; i < vc->_sections.count; i++) {
		if ([vc->_sections[i] rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound) {
			continue;
		}
		if (index < 0 || index >= (NSInteger)vc->_rows[i].count) {
			return nil;
		}
		PDRow *row = vc->_rows[i][(NSUInteger)index];
		if (row.kind != PDRowSegmented) {
			return nil;
		}
		NSIndexPath *ip = [NSIndexPath indexPathForRow:index inSection:(NSInteger)i];
		UITableViewCell *cell = [vc.tableView cellForRowAtIndexPath:ip];
		UISegmentedControl *sc = (UISegmentedControl *)cell.accessoryView;
		if (![sc isKindOfClass:UISegmentedControl.class]) {
			return nil;
		}
		if (seg < 0 || seg >= (NSInteger)sc.numberOfSegments) {
			return nil;
		}
		sc.selectedSegmentIndex = seg;
		[vc segChanged:sc];
		return [NSString stringWithFormat:@"%@/%@ -> %@", vc->_sections[i], row.title,
			row.values[(NSUInteger)seg]];
	}
	return nil;
}

+ (NSString *)pressRowInSection:(NSString *)needle atIndex:(NSInteger)index
{
	NSCAssert(NSThread.isMainThread, @"UIKit");
	PDSettingsViewController *vc = [self presentedController];
	if (!vc) {
		return nil;
	}
	for (NSUInteger i = 0; i < vc->_sections.count; i++) {
		if ([vc->_sections[i] rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound) {
			continue;
		}
		if (index < 0 || index >= (NSInteger)vc->_rows[i].count) {
			return nil;
		}
		NSIndexPath *ip = [NSIndexPath indexPathForRow:index inSection:(NSInteger)i];
		PDRow *row = vc->_rows[i][(NSUInteger)index];
		[vc tableView:vc.tableView didSelectRowAtIndexPath:ip];
		return [NSString stringWithFormat:@"%@/%@", vc->_sections[i], row.title];
	}
	return nil;
}

+ (void)rebuildRows
{
	dispatch_async(dispatch_get_main_queue(), ^{
		PDSettingsViewController *vc = [self presentedControllerEvenIfHidden];
		[vc buildRows];
		[vc.tableView reloadData];
	});
}

+ (void)reloadRows
{
	dispatch_async(dispatch_get_main_queue(), ^{
		// Even if hidden: the page outlives a dismiss now (D-041), and a default
		// changed while it is closed has to be on the row when it comes back.
		[[self presentedControllerEvenIfHidden].tableView reloadData];
	});
}

+ (void)scrollToSectionContaining:(NSString *)needle
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToSectionContaining:needle]; });
		return;
	}
	PDSettingsViewController *vc = [self presentedController];
	[vc scrollTo:needle];
}

- (void)scrollTo:(NSString *)needle
{
	// The page may have been presented microseconds ago and not laid out yet,
	// in which case the table has no geometry to scroll and the request is
	// silently dropped (it was: `settings xbla` screenshotted the Aiming
	// section). Force the layout first.
	[self.view layoutIfNeeded];
	[self.tableView layoutIfNeeded];
	for (NSUInteger i = 0; i < _sections.count; i++) {
		if ([_sections[i] rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound) {
			continue;
		}
		// A section can legitimately have no rows - Audio is a header waiting
		// for round B - and scrollToRowAtIndexPath: on one raises NSRangeException
		// and takes the app with it (measured, 2026-09-14). Scroll to the
		// HEADER, which every section has.
		if (_rows[i].count == 0) {
			[self.tableView scrollRectToVisible:[self.tableView rectForHeaderInSection:(NSInteger)i]
			                           animated:NO];
		} else {
			[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)i]
			                      atScrollPosition:UITableViewScrollPositionTop animated:NO];
		}
		NSLog(@"perfectdark: [settings] scrolled to section %lu (%@)", (unsigned long)i, _sections[i]);
		return;
	}
	NSLog(@"perfectdark: [settings] no section matching %@", needle);
}

+ (void)setSwitchRow:(NSString *)defaultsKey to:(BOOL)on
{
	[NSUserDefaults.standardUserDefaults setBool:on forKey:defaultsKey];
	[PDShell.shared enqueue:^{
		PDDefaultsApplyToEngine();
		configSave("$S/pd.ini");
	}];
	dispatch_async(dispatch_get_main_queue(), ^{
		[[self presentedController].tableView reloadData];
	});
}

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)buildRows
{
	__weak typeof(self) weakSelf = self;

	_sections = @[ @"Aiming", @"Controls", @"Display", @"Audio",
	               @"Xbox 360 (XBLA)", @"Texture packs", @"Diagnostics" ];
	_rows = @[
		@[
			// bean's names, and his 0.30 - the 0.20 seed was the family's
			// starting point for a tuning round and this is the round (Q-004).
			pdSliderRow(@"Look speed", PDDefLookDegPerPoint, 0.05f, 0.60f),
			pdSliderRow(@"Vertical look speed", PDDefLookDegPerPointY, 0.05f, 0.60f),
			pdSwitchRow(@"Invert look (vertical)", PDDefInvertY),
			pdSliderRow(@"Gamepad look speed", PDDefPadLookSpeed, 60.0f, 540.0f),
		],
		@[
			pdSegRow(@"Control style", PDDefControlStyle,
				@[ @"Dual analogue", @"N64 (digital)" ], @[ @0, @1 ]),
			pdSegRow(@"On-screen controls", PDDefTouchMode,
				@[ @"Auto", @"On", @"Off" ], @[ @0, @1, @2 ]),
			pdSliderRow(@"Button opacity", PDDefButtonOpacity, 0.05f, 0.9f),
#if !TARGET_OS_VISION
			// Compiled out on visionOS, as bean's is: there are no haptics in
			// the headset, and a row that drives nothing is a row that lies.
			pdSwitchRow(@"Haptics", PDDefHaptics),
#endif
			// One setting, both gestures (D-037): a double tap of the touch
			// stick, and a double flick of a gamepad's left stick.
			pdSwitchRow(@"Double-tap / double-flick stick to roll", PDDefDoubleTapRoll),
			// The layout editor - which now owns the size as well, so there is
			// no "Button size" row here. Closing this page first is not
			// tidiness: the settings window sits at UIWindowLevelAlert over the
			// game, so the buttons being dragged are underneath it.
			pdButtonRow(@"Customize Touch Layout…", ^{
				[PDSettingsViewController dismiss];
				dispatch_async(dispatch_get_main_queue(), ^{
					[PDTouchOverlay.current beginLayoutEditing];
				});
			}),
		],
		@[
			// The Frame rate row, and the one-line insurance behind it (D-044).
			//
			// 120 -> 60 on the user's 120 Hz phone has wedged the app on every
			// build since round P, and the cause is not found yet. If round S's
			// instruments do not name it, `pd.video.hide60on120` (registered NO,
			// flipped by the bridge's `hide60 on`) takes the 60 segment off the
			// row on a ProMotion panel entirely: the player keeps 120, which is
			// the rate that works, and nothing else in the build has to wait for
			// the answer. OFF here deliberately, so the failure can still be
			// reproduced on the phone.
			//
			// D-056: the HIGH segment is the panel's own maximum, not a
			// hard-coded 120 — 120 on a ProMotion phone, 90 on this Vision Pro,
			// and on a 60 Hz panel there is one segment because there is one
			// rate. Offering a rate the panel cannot serve is what made the
			// headset read "set to 120, running at 60".
			pdFrameRateRow(),
			// Render scale. The engine draws at the drawable's size and every
			// buffer it owns is that size, so this is a launch-time input - see
			// the footer.
#if TARGET_OS_VISION
			// The headset's window is 1280x720 POINTS at contentsScale 2, so
			// native is 2560x1440 and 150% is contentsScale 3 -> 3840x2160
			// (D-032, M-028). Experimental until there is a device number.
			pdSegRow(@"Resolution", PDDefRenderScalePct,
				@[ @"1440p (Native)", @"4K (experimental)" ], @[ @100, @150 ]),
#else
			pdSegRow(@"Resolution", PDDefRenderScalePct,
				@[ @"Native", @"75%", @"50%" ], @[ @100, @75, @50 ]),
#endif
			pdSwitchRow(@"Show FPS", PDDefShowFPS),
		],
		@[
			// the user: "the main point is the game volume and the Other App Audio
			// option". Three rows, bean's three, in his order (D-033). The
			// game's own Sound / Music / Sound Mode are the eeprom's and stay in
			// the game's own Audio Options page - mirroring them here is what
			// round 1 did and what this replaced.
			pdChoiceRow(@"Other App Audio", ^NSString *{
				NSInteger m = PDDefInt(PDDefAudioSessionMode);
				if (m < 0 || m >= (NSInteger)PDAudio.modeTitles.count) {
					m = 2;
				}
				return PDAudio.modeTitles[(NSUInteger)m];
			}, ^{
				PDAudioModeViewController *picker =
					[[PDAudioModeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
				picker.onPick = ^{ [weakSelf.tableView reloadData]; };
				UINavigationController *nav =
					[[UINavigationController alloc] initWithRootViewController:picker];
				nav.modalPresentationStyle = UIModalPresentationFormSheet;
				// The bar belongs to the navigation controller, not the picker:
				// without this its title drew black on the dark sheet.
				nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
				UIViewController *top = sWindow.rootViewController;
				while (top.presentedViewController) {
					top = top.presentedViewController;
				}
				[top presentViewController:nav animated:YES completion:nil];
			}),
			pdPercentSliderRow(@"Volume", PDDefAudioMasterVolume),
			pdSwitchRow(@"Mute", PDDefAudioMute),
		],
		@[
			// ONE switch, the F6 equivalent: it drives all five parts together
			// (xblaswitch.c), which is what F6 does and what a player means.
			pdSwitchRow(@"Xbox 360 textures and models", PDDefXblaWholeRelease),
			// What is in Documents/added-content (or the legacy xbla/), named. The engine's own
			// xblaImportIsAvailable() answers yes/no and nothing else, and a
			// player whose file was not recognised needs to be told which file
			// was looked at, not just that something went wrong (D-018).
			pdInfoRow(@"Package", ^NSString *{
				// PDXbla.cachedScan, not PDXbla.scan: the scan walks
				// Documents/xbla and reads an archive header, and this block
				// runs on every dequeue of this cell (D-032).
				PDXblaFind *f = PDXbla.cachedScan;
				if (!f.found) {
					return @"none in Documents/added-content";
				}
				if (PDXbla.unpacking) {
					return [NSString stringWithFormat:@"%@ — unpacking %d%%",
						f.relativePath, PDXbla.unpackPercent];
				}
				return [NSString stringWithFormat:@"%@ (%.0f MB)%@", f.relativePath,
					(double)f.bytes / (1024.0 * 1024.0),
					(f.kind == PDXblaPackage || PDXbla.isUnpacked) ? @", ready" : @", not unpacked yet"];
			}),
			pdButtonRow(@"Add or replace the package…", ^{
				UIViewController *top = sWindow.rootViewController;
				while (top.presentedViewController) {
					top = top.presentedViewController;
				}
				[PDXbla presentImporterFrom:top done:^(PDXblaFind *f) {
					NSLog(@"perfectdark: [settings] xbla now: %@", f.headline);
					[PDShell.shared enqueue:^{ xblaImportRedetect(); }];
					[weakSelf.tableView reloadData];
				}];
			}),
		],
		@[
			pdSwitchRow(@"Texture packs", PDDefTexturePacks),
			pdButtonRow(@"Reload packs (F9)", ^{
				[PDShell.shared enqueue:^{ texpackReload(); }];
			}),
		],
		@[
			pdInfoRow(@"Build", ^NSString *{ return @(PD_IOS_BUILD_STAMP); }),
			pdInfoRow(@"Version", ^NSString *{ return @(PD_IOS_MARKETING_VERSION); }),
			pdInfoRow(@"Console bridge", ^NSString *{
#ifdef PD_PUBLIC
				return @"off (public build)";
#else
				return @"tcp :8775";
#endif
			}),
			pdInfoRow(@"FPS", ^NSString *{ return [NSString stringWithFormat:@"%.1f", videoGetAverageFPS()]; }),
			pdButtonRow(@"Take a screenshot (F12)", ^{
				[PDShell.shared enqueue:^{ screenshotRequest(); }];
			}),
			pdButtonRow(@"Save settings now", ^{
				[PDShell.shared enqueue:^{
					inputSaveBinds();
					configSave("$S/pd.ini");
				}];
				[weakSelf.tableView reloadData];
			}),
		],
	];
}

/** Any row changed: write the defaults through and re-apply at a frame boundary. */
- (void)commit
{
	// NSUserDefaults is already the truth the moment the setter returns; the
	// old -synchronize here ran on EVERY value-changed sample of a slider,
	// which is sixty blocking round trips to cfprefsd per drag (D-032).
	//
	// The engine push and the pd.ini write are coalesced the way bean's
	// PersistSettings does it: 0.4 s after the last change, so a dragged slider
	// pushes once at the end of the drag rather than once per pixel.
	[PDTouchOverlay.current applySettings];
	// Volume and Mute must not wait for the coalescing timer below: a mute the
	// player taps is expected to be silent NOW, and a dragged volume slider
	// that only lands 0.4 s after the thumb stops is a slider you cannot hear
	// yourself setting. One atomic store, so it is free to do it every sample.
	[PDAudio gainChanged];

	static NSInteger pending = 0;
	const NSInteger mine = ++pending;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			if (mine != pending) {
				return;
			}
			PDLifecycle("settings: coalescer fired — queued on the frame hook");
			[PDShell.shared enqueue:^{
				PDLifecycle("settings: coalesced apply — running on the frame hook");
				PDDefaultsApplyToEngine();
				// pd.ini is written straight away rather than at resign-active:
				// a settings change the player then swipes away should not be
				// lost, and the write is a few hundred bytes.
				configSave("$S/pd.ini");
			}];
		});
}

// --- table -----------------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_sections.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sections[(NSUInteger)s]; }

/**
 * D-019: the whole-release switch is not symmetrical, and the footer says so.
 *
 * Measured in Chicago on lane 3 (M-016): turning the release OFF changes the
 * picture at once - the walls go from 4J's to the ROM's between one screenshot
 * and the next. Turning it back ON does not bring it back; the level goes on
 * drawing the stock art until it is loaded again, at which point all of it
 * returns. Upstream writes the models half of this down (a model is matched
 * against the release's copy as it LOADS, and going back over the loaded
 * modeldefs instead crashes, because one can be freed inside a stage and its
 * memory reused - CLAUDE-notes/xbla.md); the rooms and the textures behave the
 * same way here.
 *
 * Not a thing to fix from the shell - it is the engine's own switch, and the
 * same code F6 runs. A thing to SAY, under the section, where a phone player
 * reads it before flipping rather than after.
 */
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s
{
	if ([_sections[(NSUInteger)s] isEqualToString:@"Controls"]) {
		return @"Dual analogue is the port's own control style (\"Port/Ext\"): the stick walks and "
		        "runs at the speed you push it, and dragging looks. N64 puts the stick back on the "
		        "four C directions, which is on or off with no speed in between. "
		        "In a menu, tap an item to choose it and drag up or down to scroll. "
		        "Double-tap the left of the screen to roll that way, the middle of it to roll "
		        "the other.";
	}
	if ([_sections[(NSUInteger)s] isEqualToString:@"Display"]) {
		return @"Resolution changes take effect the next time the app starts: the drawable's size "
		        "is fixed when the renderer comes up and every buffer the game owns is that size. "
		        "Lower it if the frame rate dips; Native is the panel's own.";
	}
	if ([_sections[(NSUInteger)s] isEqualToString:@"Audio"]) {
		return @"Game volume and how Perfect Dark shares the speaker with other apps.";
	}
	if ([_sections[(NSUInteger)s] isEqualToString:@"Xbox 360 (XBLA)"]) {
		return @"One switch for the whole release — 4J's textures, models, rooms, font and "
		        "explosions together, the same thing F6 does on a desktop. "
		        "Turning the release off changes the picture straight away. Turning it back on "
		        "takes effect from the next level you load — the level you are standing in "
		        "keeps the art it loaded with.";
	}
	return nil;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_rows[(NSUInteger)s].count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
	PDRow *row = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.textLabel.text = row.title;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	switch (row.kind) {
	case PDRowSwitch: {
		UISwitch *sw = [UISwitch new];
		sw.on = PDDefBool(row.key);
		objc_setAssociatedObject(sw, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		break;
	}
	case PDRowSlider: {
		UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
		sl.minimumValue = row.min;
		sl.maximumValue = row.max;
		sl.value = PDDefFloat(row.key);
		objc_setAssociatedObject(sl, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sl;
		cell.detailTextLabel.text = pdSliderText(row, PDDefFloat(row.key));
		break;
	}
	case PDRowSegmented: {
		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:row.choices];
		NSInteger v = PDDefInt(row.key);
		seg.selectedSegmentIndex = [row.values indexOfObject:@(v)];
		if (seg.selectedSegmentIndex == (NSInteger)NSNotFound) {
			seg.selectedSegmentIndex = 0;
		}
		objc_setAssociatedObject(seg, @selector(commit), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = seg;
		break;
	}
	case PDRowInfo:
		cell.detailTextLabel.text = row.info ? row.info() : @"";
		break;
	case PDRowButton:
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		if (row.info) {
			// A choice row, not an action: it reads as a setting showing its
			// current value, so it keeps the label colour every other row has
			// and takes the chevron that says "this opens something".
			cell.detailTextLabel.text = row.info();
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		} else {
			cell.textLabel.textColor = cell.tintColor;
		}
		break;
	}
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
	PDRow *row = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (row.kind == PDRowButton && row.action) {
		row.action();
	}
}

- (void)switchChanged:(UISwitch *)sw
{
	PDRow *row = objc_getAssociatedObject(sw, @selector(commit));
	[NSUserDefaults.standardUserDefaults setBool:sw.on forKey:row.key];
	[self commit];
}

- (void)sliderChanged:(UISlider *)sl
{
	PDRow *row = objc_getAssociatedObject(sl, @selector(commit));
	if (row.percent) {
		// Snap to whole percent: 0.437 has no meaning to a player and the label
		// would disagree with the value on the next reload.
		sl.value = roundf(sl.value * 100.0f) / 100.0f;
		[NSUserDefaults.standardUserDefaults setFloat:sl.value forKey:row.key];
	} else if (row.unit) {
		// A whole-number row snaps, for the same reason.
		sl.value = roundf(sl.value);
		[NSUserDefaults.standardUserDefaults setInteger:(NSInteger)sl.value forKey:row.key];
	} else {
		[NSUserDefaults.standardUserDefaults setFloat:sl.value forKey:row.key];
	}
	[self commit];
	// The value label beside it, without reloading the whole table under the
	// finger that is still on the slider.
	UITableViewCell *cell = (UITableViewCell *)sl.superview;
	if ([cell isKindOfClass:UITableViewCell.class]) {
		cell.detailTextLabel.text = pdSliderText(row, sl.value);
	}
}

- (void)segChanged:(UISegmentedControl *)seg
{
	PDRow *row = objc_getAssociatedObject(seg, @selector(commit));
	NSInteger idx = seg.selectedSegmentIndex;
	if (idx >= 0 && idx < (NSInteger)row.values.count) {
		PDLifecycle("settings SEG \"%s\" -> %s", row.title.UTF8String,
			row.values[(NSUInteger)idx].stringValue.UTF8String);
		[NSUserDefaults.standardUserDefaults setInteger:row.values[(NSUInteger)idx].integerValue forKey:row.key];
		[self commit];
	}
}

@end
