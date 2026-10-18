#import <Foundation/Foundation.h>

/// This file contains wrappers around various ObjC functions so we can catch
/// exceptions, since you can't natively catch ObjC exceptions from Swift
/// (at least at the time of writing this comment).

/// NSWindow.addTabbedWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyAddTabbedWindowSafely(
    id _Nonnull parent,
    id _Nonnull child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
);

/// NSWindowController.showWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyShowWindowSafely(
    id _Nonnull controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);

/// -[NSAttributedString size] / -boundingRectWithSize:options: wrapper.
/// `wrapWidth` > 0 measures the text wrapped at that width, otherwise on
/// one line. `failForTesting` raises the exception CoreText raised in the
/// crash of task 1718, inside the guard, instead of measuring.
FOUNDATION_EXPORT BOOL GhosttyMeasureTextSafely(
    NSAttributedString * _Nonnull text,
    CGFloat wrapWidth,
    BOOL failForTesting,
    CGSize * _Nonnull size,
    NSError * _Nullable * _Nullable error
);
