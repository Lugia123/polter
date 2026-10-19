#import "ObjCExceptionCatcher.h"

#import <AppKit/AppKit.h>

static NSError *GhosttyErrorFromException(NSException *exception, NSInteger code) {
    NSString *reason = exception.reason ?: @"Unknown Objective-C exception";
    return [NSError errorWithDomain:@"Ghostty.ObjCException"
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: reason,
                               @"exception_name": exception.name,
                           }];
}

BOOL GhosttyAddTabbedWindowSafely(
    id parent,
    id child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
) {
    // AppKit occasionally throws NSException while adding tabbed windows,
    // in particular when creating tabs from the tab overview page since some
    // macOS update recently in 2025/2026 (unclear).
    //
    // We must catch it in Objective-C; letting this cross into Swift is unsafe.
    @try {
        [((NSWindow *)parent) addTabbedWindow:(NSWindow *)child ordered:(NSWindowOrderingMode)ordered];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = GhosttyErrorFromException(exception, 1);
        }

        return NO;
    }
}

BOOL GhosttyShowWindowSafely(
    id controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
) {
    // Selecting a newly added tab can throw from NSWindowStackController when
    // the tab group contains windows in inconsistent native fullscreen states.
    // Catch the exception here so the AppKit assertion doesn't abort the app.
    @try {
        [((NSWindowController *)controller) showWindow:sender];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = GhosttyErrorFromException(exception, 2);
        }

        return NO;
    }
}

BOOL GhosttyMeasureTextSafely(
    NSAttributedString *text,
    CGFloat wrapWidth,
    BOOL failForTesting,
    CGSize *size,
    NSError * _Nullable * _Nullable error
) {
    // CoreText once threw from TAttributes::ApplyFont while measuring a
    // terminal's title for the control room ("attempt to insert nil object
    // from objects[0]"), on the main thread in the middle of a SwiftUI
    // layout, which aborted the app (task 1718). The font was nil: CoreText
    // copies the attributes when it finds no font in them, and the nil value
    // cannot go into the copy (task 1753, reproduced frame for frame).
    // ⚠️ This @try does NOT catch that throw: it comes out of CoreText, and
    // in a plain Objective-C program the same @try catches a direct throw
    // and still aborts on this one (measured, task 1753). `SafeFace` is what
    // keeps a nil font from getting here. This stays for throws it can
    // catch.
    @try {
        if (failForTesting) {
            // The same exception from the same class: a dictionary given nil.
            id objects[1] = { nil };
            id keys[1] = { NSFontAttributeName };
            (void)[[NSDictionary alloc] initWithObjects:objects forKeys:keys count:1];
        }
        if (wrapWidth > 0) {
            *size = [text boundingRectWithSize:NSMakeSize(wrapWidth, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin].size;
        } else {
            *size = [text size];
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = GhosttyErrorFromException(exception, 3);
        }

        return NO;
    }
}

NSFont * _Nullable GhosttySystemFontOrNil(CGFloat size, CGFloat weight, BOOL monospaced) {
    return monospaced
        ? [NSFont monospacedSystemFontOfSize:size weight:weight]
        : [NSFont systemFontOfSize:size weight:weight];
}

NSFont * _Nullable GhosttyMenuFontOrNil(CGFloat size) {
    return [NSFont menuFontOfSize:size];
}

NSFont * _Nullable GhosttyTitleBarFontOrNil(CGFloat size) {
    return [NSFont titleBarFontOfSize:size];
}
