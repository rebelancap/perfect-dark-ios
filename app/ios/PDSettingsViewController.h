// PDSettingsViewController.h — the native settings page (gear button, and the
// bridge's `settings` command). NSUserDefaults is the truth; PDDefaults pushes
// it into the engine.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PDSettingsViewController : UITableViewController

/** Show it (main thread). Idempotent. */
+ (void)present;
/** Hide it. */
+ (void)dismiss;
/** Whether it is up — the bridge reports this in `state`. */
+ (BOOL)isPresented;

/**
 * Build the page now, hidden, so the FIRST gear tap costs what the second one
 * does (BUG 4 / D-041). Called once from the shell shortly after the engine is
 * up. Idempotent; any thread.
 */
+ (void)prewarm;

/**
 * Release the page's window outright — the round-R dismiss deliberately does
 * NOT (D-041), and this exists only as one of the numbered `heal` experiments.
 */
+ (void)destroy;

/**
 * Set one switch row's value exactly as a finger on that row would: the
 * default is written, then PDDefaultsApplyToEngine() runs at a frame boundary
 * and pd.ini is saved. The bridge uses it so that a scripted check of "does the
 * whole-release row actually do anything" is a check of the ROW, not of a
 * private path that happens to call the same engine function.
 */
+ (void)setSwitchRow:(NSString *)defaultsKey to:(BOOL)on;

/**
 * Press row `index` of the first section whose title contains `needle`, exactly
 * as a finger on it would (the same -tableView:didSelectRowAtIndexPath:).
 *
 * The bridge's `tap` drives the TOUCH OVERLAY, not UIKit, so until this existed
 * there was no scripted way to open anything the settings page presents - the
 * Other App Audio sheet among them. Returns what it pressed, or nil.
 */
+ (nullable NSString *)pressRowInSection:(NSString *)needle atIndex:(NSInteger)index;

/**
 * Move a SEGMENTED row to one of its segments, through the control's own
 * -segChanged: — the only scripted path to the Frame rate row, which
 * `settings row` cannot touch because a segmented row has no row action
 * (D-041 round 2).
 */
+ (nullable NSString *)setSegmentInSection:(NSString *)needle atIndex:(NSInteger)index to:(NSInteger)seg;

/** Redraw every row from the defaults, if the page is up. Any thread. */
+ (void)reloadRows;

/**
 * Rebuild the ROW LIST, not just the values (D-044).
 *
 * -reloadRows re-reads each row's default into the cell it already has; this
 * is for the case where which rows EXIST has changed — `hide60 on|off`, which
 * adds or removes the 60 Hz segment of the Frame rate row.
 */
+ (void)rebuildRows;

/** Scroll the page to the section whose title contains `needle`. */
+ (void)scrollToSectionContaining:(NSString *)needle;

@end

NS_ASSUME_NONNULL_END
