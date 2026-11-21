#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface XnkAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSWindow *window;
@property (strong, nonatomic) WKWebView *webView;
@property (copy, nonatomic) NSString *initialURL;
@property (copy, nonatomic) NSString *windowTitle;
@property (assign, nonatomic) NSInteger width;
@property (assign, nonatomic) NSInteger height;
@end

@implementation XnkAppDelegate

- (void)setupMenus {
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];

    NSMenu *appMenu = [[NSMenu alloc] init];
    NSString *appName = self.windowTitle ?: @"XNK Disk";
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"]];
    [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"]];
    [windowMenuItem setSubmenu:windowMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setupMenus];

    NSRect frame = NSMakeRect(0, 0, self.width > 0 ? self.width : 1280, self.height > 0 ? self.height : 780);
    NSWindowStyleMask style = NSWindowStyleMaskTitled |
                              NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:self.windowTitle ?: @"XNK Disk"];
    [self.window setMinSize:NSMakeSize(820, 520)];
    [self.window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [self.window setBackgroundColor:[NSColor blackColor]];
    [self.window setDelegate:self];
    [self.window center];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:[[self.window contentView] bounds] configuration:config];
    [self.webView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [[self.window contentView] addSubview:self.webView];

    NSURL *url = [NSURL URLWithString:self.initialURL];
    if (url != nil) {
        NSURLRequest *req = [NSURLRequest requestWithURL:url];
        [self.webView loadRequest:req];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

void xnk_run_webview(const char *urlCStr, const char *titleCStr, int width, int height) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        XnkAppDelegate *delegate = [[XnkAppDelegate alloc] init];
        delegate.initialURL = [NSString stringWithUTF8String:urlCStr];
        delegate.windowTitle = [NSString stringWithUTF8String:titleCStr];
        delegate.width = width;
        delegate.height = height;

        [NSApp setDelegate:delegate];
        [NSApp run];
    }
}
