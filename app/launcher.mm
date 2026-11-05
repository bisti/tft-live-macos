#import <Cocoa/Cocoa.h>

static NSString *resources() { return NSBundle.mainBundle.resourcePath; }
static NSString *pythonPath() { return [resources() stringByAppendingPathComponent:@"python/bin/python3"]; }
static NSString *dataPath() {
    NSString *override = NSProcessInfo.processInfo.environment[@"TFT_LIVE_DATA_DIR"];
    return override.length ? override.stringByExpandingTildeInPath : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TFT Live"];
}

@interface TFTLauncher : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@property NSProgressIndicator *spinner;
@property NSTask *task;
@property NSFileHandle *reader;
@property NSTimer *timer;
@property NSMutableData *pending;
@property NSString *lastLine;
@end

@implementation TFTLauncher
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application { return YES; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 155)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"TFT Live";
    [self.window center];
    self.status = [NSTextField wrappingLabelWithString:@"Preparing Riot Client…"];
    self.status.frame = NSMakeRect(28, 48, 424, 60);
    self.status.font = [NSFont systemFontOfSize:14];
    [self.window.contentView addSubview:self.status];
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(28, 24, 424, 12)];
    self.spinner.style = NSProgressIndicatorStyleBar;
    self.spinner.indeterminate = YES;
    [self.spinner startAnimation:nil];
    [self.window.contentView addSubview:self.spinner];
    [self.window makeKeyAndOrderFront:nil];
    self.pending = [NSMutableData data];
    NSError *error = nil;
    if (!dataPath().isAbsolutePath) { [self showFailure:@"The data directory must be an absolute path."]; return; }
    if (![NSFileManager.defaultManager createDirectoryAtPath:dataPath() withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        [self showFailure:@"Unable to create the TFT Live user data directory."];
        return;
    }
    NSString *logPath = [dataPath() stringByAppendingPathComponent:@"launcher.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:logPath]) {
        [NSFileManager.defaultManager createFileAtPath:logPath contents:nil attributes:@{NSFilePosixPermissions: @0600}];
    }
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!output) { [self showFailure:@"Unable to open the TFT Live log."]; return; }
    unsigned long long start = [output seekToEndOfFile];
    self.reader = [NSFileHandle fileHandleForReadingAtPath:logPath];
    [self.reader seekToFileOffset:start];
    self.task = [[NSTask alloc] init];
    self.task.executableURL = [NSURL fileURLWithPath:pythonPath()];
    self.task.arguments = @[@"-I", @"-B", @"-u", [resources() stringByAppendingPathComponent:@"code/launch_windows_live.py"]];
    self.task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    self.task.standardOutput = output;
    self.task.standardError = output;
    __weak TFTLauncher *weakSelf = self;
    self.task.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TFTLauncher *launcher = weakSelf;
            [launcher.timer invalidate];
            [launcher readProgress];
            [launcher.reader closeFile];
            if (task.terminationStatus == 0) [NSApp terminate:nil];
            else [launcher showFailure:launcher.lastLine ?: @"Setup did not complete."];
        });
    };
    if (![self.task launchAndReturnError:&error]) {
        [output closeFile];
        [self showFailure:@"The bundled TFT Live runtime failed to start."];
        return;
    }
    [output closeFile];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(readProgress) userInfo:nil repeats:YES];
}
- (void)readProgress {
    [self.pending appendData:[self.reader readDataToEndOfFile]];
    NSString *text = [[NSString alloc] initWithData:self.pending encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    NSRange ending = [text rangeOfString:@"\n" options:NSBackwardsSearch];
    if (ending.location == NSNotFound) return;
    NSString *complete = [text substringToIndex:NSMaxRange(ending)];
    NSUInteger consumed = [complete lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [self.pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:nullptr length:0];
    for (NSString *line in [complete componentsSeparatedByString:@"\n"]) {
        NSString *value = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!value.length) continue;
        self.lastLine = value;
        if ([value hasPrefix:@"Preparing"] || [value hasPrefix:@"Sign in"] || [value hasPrefix:@"Closing"]
            || [value hasPrefix:@"Live version"] || [value hasPrefix:@"Installing"] || [value hasPrefix:@"Updating"] || [value hasPrefix:@"Update complete"]
            || [value hasPrefix:@"New Riot components"] || [value hasPrefix:@"Riot is ready"] || [value hasSuffix:@" %"]) {
            self.status.stringValue = value;
        }
    }
}
- (void)showFailure:(NSString *)message {
    [self.spinner stopAnimation:nil];
    self.spinner.hidden = YES;
    self.status.stringValue = message;
    NSButton *button = [NSButton buttonWithTitle:@"Close" target:NSApp action:@selector(terminate:)];
    button.frame = NSMakeRect(370, 15, 85, 30);
    [self.window.contentView addSubview:button];
    [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-check") == 0) {
            NSTask *check = [[NSTask alloc] init];
            check.executableURL = [NSURL fileURLWithPath:pythonPath()];
            check.arguments = @[@"-I", @"-B", @"-c",
                @"import json, pathlib, platform, ssl, sys; p=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(p)); import launch_windows_live, riot_runtime, launcher_config; print(json.dumps({'architecture':platform.machine(),'python_prefix':sys.prefix,'data_directory':str(launcher_config.data_directory()),'bundled_host':(p/'SDKHost').is_file(),'installed_riot':str(launcher_config.installed_riot())}))",
                [resources() stringByAppendingPathComponent:@"code"]];
            if (![check launchAndReturnError:nil]) return 1;
            [check waitUntilExit];
            return check.terminationStatus;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TFTLauncher *delegate = [[TFTLauncher alloc] init];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
