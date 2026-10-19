#import <Foundation/Foundation.h>

@class NSFont;

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

/// +[NSFont systemFontOfSize:weight:], or +monospacedSystemFontOfSize:weight:
/// when `monospaced`, typed as what it can really return. The SDK marks both
/// nonnull, so in Swift a nil from them is a non-optional `NSFont` that is
/// nil, which nothing can test for; one reached CoreText in the crash of
/// task 1753. Here the nil is an ordinary optional.
FOUNDATION_EXPORT NSFont * _Nullable GhosttySystemFontOrNil(
    CGFloat size,
    CGFloat weight,
    BOOL monospaced
);

/// +[NSFont menuFontOfSize:], typed as what it can really return, for the
/// same reason (task 1805). `size` 0 is AppKit's default size for it.
FOUNDATION_EXPORT NSFont * _Nullable GhosttyMenuFontOrNil(CGFloat size);

/// +[NSFont titleBarFontOfSize:], likewise (task 1805).
FOUNDATION_EXPORT NSFont * _Nullable GhosttyTitleBarFontOrNil(CGFloat size);
