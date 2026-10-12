// ParsecLowDisplay — Mac side of OpenParsec's low-resolution mode.
//
// The macOS Parsec host always streams a display at its full pixel size
// (vp_supported=0). This LaunchAgent creates a virtual display "Parsec Low"
// at a fraction of that size and makes the streamed physical display mirror
// it, so Parsec captures (and encodes) fewer pixels. The iPad app drives it
// with hotkeys sent through the Parsec session (Carbon hotkeys: no
// Accessibility permission needed). Letters, not F13+: F-key hotkeys only fire
// when the event carries the fn flag, which a remote host can't be relied on
// to set. Ctrl+Opt+Cmd+letter is unused by macOS:
//   Ctrl+Opt+Cmd+J  ½ size (a HiDPI mode's point size: windows stay put)
//   Ctrl+Opt+Cmd+K  ⅔ size (sharper, more space)
//   Ctrl+Opt+Cmd+L  mirror the next physical display instead
//   Ctrl+Opt+Cmd+H  off
// Safety: hotkeys only act while a Parsec client is connected; the display is
// removed when the last client disconnects, the host restarts, stats stop for
// 5 min or the mirrored display goes away. If this process dies, macOS drops
// the virtual display and its mirroring by itself.
//
//   clang -fobjc-arc -framework Cocoa -framework Carbon mac-helper/ParsecLowDisplay.m -o ParsecLowDisplay
//   ./ParsecLowDisplay --self-test
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <assert.h>
#include <sys/stat.h>

// Private CoreGraphics API (macOS 11+), as used by BetterDisplay & co.
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) dispatch_queue_t queue; @property(retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters; @property(copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain) NSArray *modes; @property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s; @property(readonly) CGDirectDisplayID displayID;
@end

#pragma mark - Pure logic (covered by --self-test)

typedef struct { unsigned w, h; } PLSize;
typedef struct { CGDirectDisplayID id; unsigned w, h; } PLDisplay;
enum { PLOff = 0, PLHalf = 2, PLTwoThirds = 3, PLNext = 9 };
static const time_t PLStatsTimeout = 300;

// Exact fraction of the pixel size, rounded to even (encoders need it).
static PLSize PLScaled(unsigned w, unsigned h, int level) {
	unsigned num = level == PLTwoThirds ? 2 : 1, den = level == PLTwoThirds ? 3 : 2;
	return (PLSize){ (w * num + den) / (2 * den) * 2, (h * num + den) / (2 * den) * 2 };
}

// What the host log says about the session.
@interface PLLog : NSObject
@property NSMutableSet<NSString *> *clients; // connected right now
@property PLSize encode;                     // last capture size
@property time_t lastSeen;                   // last connect or "[0] FPS:" line
@end
@implementation PLLog
- (instancetype)init { if ((self = [super init])) _clients = [NSMutableSet set]; return self; }
- (void)feed:(NSString *)line {
	// "[D 2026-10-13 00:46:17] message"
	if (line.length < 24 || [line characterAtIndex:0] != '[') return;
	NSString *msg = [line substringFromIndex:24];
	if ([msg containsString:@"===== Parsec: Started"]) { [self.clients removeAllObjects]; self.lastSeen = 0; return; }
	if ([msg hasSuffix:@" disconnected."]) { [self.clients removeObject:[msg substringToIndex:msg.length - 14]]; return; }
	if ([msg hasPrefix:@"encode_x"]) { _encode.w = (unsigned)[[msg componentsSeparatedByString:@"="].lastObject intValue]; return; }
	if ([msg hasPrefix:@"encode_y"]) { _encode.h = (unsigned)[[msg componentsSeparatedByString:@"="].lastObject intValue]; return; }
	BOOL connected = [msg hasSuffix:@" connected."];
	if (connected) [self.clients addObject:[msg substringToIndex:msg.length - 11]];
	if (connected || [msg hasPrefix:@"[0] FPS:"]) { // stats start ~10 s after a connect
		struct tm tm = {0}; tm.tm_isdst = -1;
		if (strptime([line substringWithRange:NSMakeRange(3, 19)].UTF8String, "%Y-%m-%d %H:%M:%S", &tm)) self.lastSeen = mktime(&tm);
	}
}
- (BOOL)activeAt:(time_t)now { return self.clients.count > 0 && now - self.lastSeen < PLStatsTimeout; }
@end

// The physical display being streamed: the one whose pixel size the host is
// encoding; unknown → the main display.
static CGDirectDisplayID PLPickTarget(const PLDisplay *d, int n, PLSize encode, CGDirectDisplayID main) {
	for (int i = 0; i < n; i++) if (d[i].w == encode.w && d[i].h == encode.h) return d[i].id;
	return main;
}

static CGDirectDisplayID PLNextTarget(const PLDisplay *d, int n, CGDirectDisplayID current) {
	for (int i = 0; i < n; i++) if (d[i].id == current) return d[(i + 1) % n].id;
	return n ? d[0].id : current;
}

#pragma mark - Displays

static CGVirtualDisplay *virt;
static CGDirectDisplayID target;
static int level;
static PLLog *plog;

// Online physical displays (the virtual one excluded) with their current pixel size.
static int PLPhysical(PLDisplay *out, int max) {
	CGDirectDisplayID ids[16]; uint32_t n = 0; int k = 0;
	CGGetOnlineDisplayList(16, ids, &n);
	for (uint32_t i = 0; i < n && k < max; i++) {
		if (virt && ids[i] == virt.displayID) continue;
		CGDisplayModeRef m = CGDisplayCopyDisplayMode(ids[i]);
		if (!m) continue;
		out[k++] = (PLDisplay){ ids[i], (unsigned)CGDisplayModeGetPixelWidth(m), (unsigned)CGDisplayModeGetPixelHeight(m) };
		CGDisplayModeRelease(m);
	}
	return k;
}

// Mirroring changes the slave's display mode and can hand "main" (menu bar) to
// another display; macOS doesn't undo either on unmirror. Our changes are
// session-only, so the user's saved arrangement is the way back.
static void PLRestore(void) { CGRestorePermanentDisplayConfiguration(); }

static void PLRemove(NSString *why) {
	if (!virt) return;
	NSLog(@"off (%@)", why);
	virt = nil; target = 0; level = PLOff; // dealloc removes the display
	PLRestore();
}

static BOOL busy; // PLApply spins the run loop: no re-entry from timers/hotkeys

// One display reconfiguration, retried: a new virtual display (or a mode it
// was just given) takes a moment to show up, and configuring it before that
// fails with kCGErrorFailure. Wait by running the main run loop, never by
// sleeping: CoreGraphics refreshes its view of the displays (modes, online
// state) from notifications delivered there.
static CGError PLConfigure(void (^body)(CGDisplayConfigRef c, BOOL *ready)) {
	CGError e = kCGErrorFailure;
	for (int attempt = 0; attempt < 30 && e; attempt++) {
		if (attempt) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		CGDisplayConfigRef c; BOOL ready = YES;
		if (CGBeginDisplayConfiguration(&c)) continue;
		body(c, &ready);
		if (!ready) { CGCancelDisplayConfiguration(c); continue; }
		e = CGCompleteDisplayConfiguration(c, kCGConfigureForSession);
	}
	return e;
}

// Size the virtual display for `display` at `lvl` and mirror `display` into it.
// Every change starts from the user's own arrangement: a mirrored display's
// mode can't be changed, and the next target must be measured unmirrored.
static void PLApply(CGDirectDisplayID display, int lvl) {
	if (target) {
		CGDirectDisplayID old = target;
		PLConfigure(^(CGDisplayConfigRef c, BOOL *ready) { CGConfigureDisplayMirrorOfDisplay(c, old, kCGNullDirectDisplay); });
		PLRestore(); target = 0;
	}
	PLDisplay d[16], *p = NULL; int n = PLPhysical(d, 16);
	for (int i = 0; i < n; i++) if (d[i].id == display) p = &d[i];
	if (!p) { PLRemove(@"display gone"); return; }
	PLSize s = PLScaled(p->w, p->h, lvl);
	CGPoint origin = CGDisplayBounds(display).origin;
	if (!virt) {
		CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
		desc.queue = dispatch_get_main_queue();
		desc.name = @"Parsec Low"; // the app finds it by this name
		desc.maxPixelsWide = 7680; desc.maxPixelsHigh = 4320;
		desc.sizeInMillimeters = CGSizeMake(s.w * 0.21, s.h * 0.21);
		desc.vendorID = 0x1234; desc.productID = 0x5678; desc.serialNum = 1;
		virt = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
		if (!virt) { NSLog(@"create failed"); return; }
	}
	CGVirtualDisplaySettings *set = [CGVirtualDisplaySettings new];
	set.hiDPI = 0; set.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:s.w height:s.h refreshRate:60]];
	if (![virt applySettings:set]) { NSLog(@"mode %ux%u failed", s.w, s.h); PLRemove(@"mode failed"); return; }
	CGDirectDisplayID v = virt.displayID;
	// applySettings only offers the mode; an existing display keeps its old one.
	CGError e = PLConfigure(^(CGDisplayConfigRef c, BOOL *ready) {
		CFArrayRef modes = CGDisplayCopyAllDisplayModes(v, NULL);
		CGDisplayModeRef mode = NULL;
		for (CFIndex m = 0; modes && m < CFArrayGetCount(modes) && !mode; m++) {
			CGDisplayModeRef x = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, m);
			if (CGDisplayModeGetPixelWidth(x) == s.w && CGDisplayModeGetPixelHeight(x) == s.h) mode = x;
		}
		if (mode) CGConfigureDisplayWithDisplayMode(c, v, mode, NULL); else *ready = NO;
		if (modes) CFRelease(modes);
	});
	if (!e) e = PLConfigure(^(CGDisplayConfigRef c, BOOL *ready) {
		CGConfigureDisplayMirrorOfDisplay(c, display, v);
		CGConfigureDisplayOrigin(c, v, (int32_t)origin.x, (int32_t)origin.y); // keeps main + arrangement
	});
	target = display; level = lvl;
	if (e) { NSLog(@"display %u at %ux%u failed: %d", display, s.w, s.h, e); PLRemove(@"configure failed"); return; }
	NSLog(@"on: display %u → %ux%u (virtual %u)", display, s.w, s.h, v);
}

static void PLReadLog(void);

static void PLHotkey(int key) {
	if (busy) { NSLog(@"hotkey %d ignored: busy", key); return; }
	PLReadLog(); // the connect line may be newer than the last poll
	if (![plog activeAt:time(NULL)]) { NSLog(@"hotkey %d ignored: no Parsec session", key); return; }
	if (key == PLOff) { PLRemove(@"hotkey"); return; }
	if (virt && key == level) return; // already there: don't blink the screens
	PLDisplay d[16]; int n = PLPhysical(d, 16);
	busy = YES;
	if (key == PLNext) { if (virt) PLApply(PLNextTarget(d, n, target), level); }
	else PLApply(virt ? target : PLPickTarget(d, n, plog.encode, CGMainDisplayID()), key);
	busy = NO;
}

#pragma mark - Host log

static NSString *logPath;
static unsigned long long logOffset;
static ino_t logInode;
static NSMutableString *partial;

static void PLReadLog(void) {
	struct stat st;
	if (stat(logPath.fileSystemRepresentation, &st) == 0) {
		if (st.st_ino != logInode || (unsigned long long)st.st_size < logOffset) { logInode = st.st_ino; logOffset = 0; [partial setString:@""]; }
		if ((unsigned long long)st.st_size > logOffset) {
			NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:logPath];
			[f seekToFileOffset:logOffset];
			NSData *data = [f readDataToEndOfFile];
			[f closeFile];
			logOffset += data.length;
			// Latin-1 never fails on a chunk that splits a UTF-8 character (UTF-8
			// would drop the whole chunk); the markers we match are ASCII.
			[partial appendString:[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]];
			NSArray *lines = [partial componentsSeparatedByString:@"\n"];
			for (NSUInteger i = 0; i + 1 < lines.count; i++) [plog feed:lines[i]];
			[partial setString:lines.lastObject];
		}
	}
}

static void PLPoll(void) {
	if (busy) return;
	PLReadLog();
	if (!virt) return;
	if (![plog activeAt:time(NULL)]) { PLRemove(@"Parsec session ended"); return; }
	PLDisplay d[16]; int n = PLPhysical(d, 16); BOOL online = NO;
	for (int i = 0; i < n; i++) online |= d[i].id == target;
	if (!online) PLRemove(@"mirrored display gone");
}

static OSStatus PLHotkeyHandler(EventHandlerCallRef next, EventRef e, void *ctx) {
	EventHotKeyID hk; GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hk, NULL, &hk);
	PLHotkey((int)hk.id);
	return noErr;
}

#pragma mark - Self-test

static void PLSelfTest(void) {
	// Retina panels: ½ is exactly the point size, ⅔ rounds to even.
	PLSize s = PLScaled(3024, 1964, PLHalf); assert(s.w == 1512 && s.h == 982);
	s = PLScaled(3840, 1608, PLHalf); assert(s.w == 1920 && s.h == 804);
	s = PLScaled(3024, 1964, PLTwoThirds); assert(s.w == 2016 && s.h == 1310);
	s = PLScaled(3840, 1608, PLTwoThirds); assert(s.w == 2560 && s.h == 1072);
	s = PLScaled(1919, 1079, PLHalf); assert(s.w % 2 == 0 && s.h % 2 == 0);

	PLLog *l = [PLLog new];
	time_t t0 = 0;
	for (NSString *line in @[
		@"[F 2026-10-13 00:50:58] ===== Parsec: Started =====",
		@"[I 2026-10-13 00:51:48] Kepel#14289710 connected.",
		@"[D 2026-10-13 00:51:48] encode_x      = 3024",
		@"[D 2026-10-13 00:51:48] encode_y      = 1964",
		@"[I 2026-10-13 00:51:50] Kepel#14289710 connected.", // reconnect without a disconnect line
		@"[D 2026-10-13 00:51:52] [0] FPS:43.9/276238, L:31.1/56.7, B:1.0/2.0, N:60/200/5",
		@"garbage", @"",
	]) [l feed:line];
	struct tm tm = {0}; tm.tm_isdst = -1; strptime("2026-10-13 00:51:52", "%Y-%m-%d %H:%M:%S", &tm); t0 = mktime(&tm);
	assert(l.encode.w == 3024 && l.encode.h == 1964);
	assert([l activeAt:t0 + 10]);
	assert(![l activeAt:t0 + PLStatsTimeout]);  // stats stopped: treat as gone
	[l feed:@"[I 2026-10-13 00:53:47] Kepel#14289710 disconnected."];
	assert(![l activeAt:t0 + 10]);
	[l feed:@"[I 2026-10-13 00:54:00] A#1 connected."];
	[l feed:@"[F 2026-10-13 00:55:00] ===== Parsec: Started ====="]; // host restart: nobody is connected
	assert(![l activeAt:t0 + 10]);
	NSString *(^latin1)(NSString *) = ^(NSString *u) { return [[NSString alloc] initWithData:[u dataUsingEncoding:NSUTF8StringEncoding] encoding:NSISOLatin1StringEncoding]; };
	[l feed:latin1(@"[I 2026-10-13 00:56:00] Игорь#7 connected.")];
	assert([l activeAt:t0 + 10]);
	[l feed:latin1(@"[I 2026-10-13 00:57:00] Игорь#7 disconnected.")];
	assert(![l activeAt:t0 + 10]);
	PLLog *fresh = [PLLog new]; // just connected, no stats yet: hotkeys must already work
	[fresh feed:@"[I 2026-10-13 00:51:52] Kepel#14289710 connected."];
	assert([fresh activeAt:t0 + 5]);

	PLDisplay d[] = { { 1, 3024, 1964 }, { 3, 3840, 1608 } };
	assert(PLPickTarget(d, 2, (PLSize){ 3840, 1608 }, 1) == 3);
	assert(PLPickTarget(d, 2, (PLSize){ 1512, 982 }, 1) == 1); // unknown size → main
	assert(PLNextTarget(d, 2, 1) == 3 && PLNextTarget(d, 2, 3) == 1);
	assert(PLNextTarget(d, 2, 7) == 1);
	puts("ParsecLowDisplay self-test: ok");
}

int main(int argc, const char **argv) { @autoreleasepool {
	if (argc > 1 && !strcmp(argv[1], "--self-test")) { PLSelfTest(); return 0; }
	plog = [PLLog new]; partial = [NSMutableString string];
	logPath = NSProcessInfo.processInfo.environment[@"PARSEC_LOG"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@".parsec/log.txt"];
	PLPoll(); // replay the current log for the session state

	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
	InstallApplicationEventHandler(&PLHotkeyHandler, 1, &spec, NULL, NULL);
	struct { UInt32 key; int action; } keys[] = { { kVK_ANSI_H, PLOff }, { kVK_ANSI_J, PLHalf }, { kVK_ANSI_K, PLTwoThirds }, { kVK_ANSI_L, PLNext } };
	for (int i = 0; i < 4; i++) {
		EventHotKeyRef ref;
		OSStatus e = RegisterEventHotKey(keys[i].key, controlKey | optionKey | cmdKey, (EventHotKeyID){ 'PLow', (UInt32)keys[i].action }, GetApplicationEventTarget(), 0, &ref);
		if (e) NSLog(@"hotkey %d not registered: %d", keys[i].action, (int)e);
	}
	[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { PLPoll(); }];
	signal(SIGTERM, SIG_IGN);
	dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(term, ^{ PLRemove(@"quit"); exit(0); });
	dispatch_resume(term);
	NSLog(@"watching %@", logPath);
	[NSApp run];
}}
