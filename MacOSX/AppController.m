/*
Copyright (C) 2007-2008 Kristian Duske

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
#import "AppController.h"
#import "ScreenInfo.h"
#include <sys/sysctl.h>	// hw.model for the settings GUI header + machine map
#include <math.h>	// fabs (slider change detection)
#if defined(SDL_FRAMEWORK) || defined(NO_SDL_CONFIG)
#if defined(USE_SDL2)
#import <SDL2/SDL.h>
#else
#import <SDL/SDL.h>
#endif
#else
#import "SDL.h"
#endif
#import "SDLMain.h"

NSString *FQPrefCommandLineKey = @"CommandLine";
NSString *FQPrefFullscreenKey = @"Fullscreen";
NSString *FQPrefScreenModeKey = @"ScreenMode";

// ======================================================================
// Settings GUI model
//
// A declarative table of the per-machine-tunable cvars, grouped into
// sections that become NSBox group panels. Each item maps a cvar to the
// UI control that fits its data type (checkbox / slider / popup) plus a
// hover tooltip. Controls are preset from the autoexec cfg that ships in
// the bundle for THIS machine, and only changed values are emitted as
// `+cvar` overrides on launch (so the autoexec stays authoritative for
// anything the user didn't touch). Keep in sync with scripts/bundle/
// autoexec-*.cfg and Quake/cl_demo.c's sysreport cvar list.
// ======================================================================
typedef enum { QST_CHECK, QST_SLIDER, QST_POPUP } qstype_t;

typedef struct { const char *display; const char *value; } qsopt_t;

typedef struct {
    const char *cvar;
    const char *label;
    const char *tip;
    qstype_t    type;
    double      vmin, vmax;   // slider range
    int         isint;        // slider snaps to integers
    const qsopt_t *opts;      // popup options, terminated by {NULL,NULL}
} qsitem_t;

typedef struct {
    const char *title;
    const qsitem_t *items;    // terminated by an item with cvar == NULL
} qssection_t;

static const qsopt_t opt_texmode[] = {
    {"Smooth (trilinear)",        "GL_LINEAR_MIPMAP_LINEAR"},
    {"Bilinear",                  "GL_LINEAR_MIPMAP_NEAREST"},
    {"Sharp / classic (nearest)", "GL_NEAREST_MIPMAP_NEAREST"},
    {NULL, NULL}
};
static const qsopt_t opt_aniso[] = {
    {"Off (1x)","1"}, {"2x","2"}, {"4x","4"}, {"8x","8"}, {"16x","16"}, {NULL,NULL}
};
static const qsopt_t opt_fsaa[] = {
    {"Off","0"}, {"2x","2"}, {"4x","4"}, {"8x","8"}, {NULL,NULL}
};
static const qsopt_t opt_subdiv[] = {
    {"Fine (64)","64"}, {"Normal (128)","128"}, {"Coarse (256)","256"}, {NULL,NULL}
};

static const qsitem_t sec_textures[] = {
    {"gl_texturemode",        "Texture filter",       "How textures are smoothed. Trilinear is smoothest; Nearest is the crisp retro look.", QST_POPUP, 0,0,0, opt_texmode},
    {"gl_texture_anisotropy", "Anisotropic filtering","Sharpens textures seen at steep angles. Higher is sharper for a small GPU cost.",     QST_POPUP, 0,0,0, opt_aniso},
    {"gl_texture_lodbias",    "Texture sharpening",   "Mip LOD bias. More negative = sharper/grainier textures in the distance.",            QST_SLIDER, -2.0, 0.0, 0, NULL},
    {NULL}
};
static const qsitem_t sec_water[] = {
    {"r_oldwater",  "Classic water warp", "On = original wavy software-style liquid surfaces. Off = flat translucent water (faster).", QST_CHECK, 0,0,0, NULL},
    {"r_wateralpha","Water transparency", "1.0 = opaque, lower lets you see through water.", QST_SLIDER, 0.0, 1.0, 0, NULL},
    {"r_lavaalpha", "Lava transparency",  "Transparency of lava surfaces.",  QST_SLIDER, 0.0, 1.0, 0, NULL},
    {"r_slimealpha","Slime transparency", "Transparency of slime surfaces.", QST_SLIDER, 0.0, 1.0, 0, NULL},
    {"r_telealpha", "Teleporter alpha",   "Transparency of teleporter surfaces.", QST_SLIDER, 0.0, 1.0, 0, NULL},
    {NULL}
};
static const qsitem_t sec_light[] = {
    {"r_shadows",                "Entity shadows",       "Blob shadows cast under monsters and items.", QST_CHECK, 0,0,0, NULL},
    {"r_shadow_distance",        "Shadow distance",      "How far away shadows still draw (0 = unlimited).", QST_SLIDER, 0, 1024, 1, NULL},
    {"r_dynamic_distance",       "Dynamic light distance","Range for dynamic lights like rockets/explosions (0 = unlimited).", QST_SLIDER, 0, 2048, 1, NULL},
    {"r_lerplightstyles",        "Smooth light pulsing", "Interpolate flickering/pulsing lights instead of stepping.", QST_CHECK, 0,0,0, NULL},
    {"r_emissive_lights",        "Emissive surface lights","Glowing textures (lights, screens) cast coloured light on nearby walls.", QST_CHECK, 0,0,0, NULL},
    {"r_emissive_lights_radius", "Emissive light radius","Reach of each emissive light.", QST_SLIDER, 0.0, 2.0, 0, NULL},
    {"r_emissive_lights_max",    "Max emissive lights",  "Cap on simultaneous emissive lights (perf).", QST_SLIDER, 0, 32, 1, NULL},
    {NULL}
};
static const qsitem_t sec_perf[] = {
    {"host_maxfps",        "Max FPS",             "Frame-rate cap. Lower can steady frame pacing on slow machines.", QST_SLIDER, 30, 250, 1, NULL},
    {"r_particles",        "Particles",           "Draw particle effects (blood, sparks, explosions).", QST_CHECK, 0,0,0, NULL},
    {"gl_clear",           "Clear screen / frame","Usually off (faster). On helps spot rendering holes.", QST_CHECK, 0,0,0, NULL},
    {"gl_zfix",            "Z-fighting fix",      "Reduces flicker on coplanar surfaces.", QST_CHECK, 0,0,0, NULL},
    {"gl_aliasstate_cache","Model state cache",   "Caches GL state for models -- a small CPU win.", QST_CHECK, 0,0,0, NULL},
    {"gl_subdivide_size",  "Sky/water subdivision","Tessellation of warped surfaces. Finer looks better, costs a little.", QST_POPUP, 0,0,0, opt_subdiv},
    {NULL}
};
static const qsitem_t sec_view[] = {
    {"viewsize", "Screen / HUD size", "120 = full screen; lower values show more of the classic HUD border.", QST_SLIDER, 30, 120, 1, NULL},
    {NULL}
};

static const qssection_t qs_sections[] = {
    {"Textures",            sec_textures},
    {"Water & liquids",     sec_water},
    {"Lighting & shadows",  sec_light},
    {"Performance",         sec_perf},
    {"View",                sec_view},
    {NULL, NULL}
};

// A top-down (flipped) document view so manual frame layout reads naturally.
@interface QSFlippedView : NSView
@end
@implementation QSFlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation AppController

+(void) initialize {
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    
    [defaults setObject:@"" forKey:FQPrefCommandLineKey];
    [defaults setObject:[NSNumber numberWithBool:YES] forKey:FQPrefFullscreenKey];
    [defaults setObject:[NSNumber numberWithInt:0] forKey:FQPrefScreenModeKey];
    
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

- (id)init {
    int i;
#ifndef USE_SDL2
    int j;
    int flags;
    int bpps[3] = {32, 24, 16};
    SDL_PixelFormat format;
    SDL_Rect **modes;
#endif
    ScreenInfo *info;

    self = [super init];
    if (!self)
        return nil;

    screenModes = [[NSMutableArray alloc] init];
    [screenModes addObject:@"Default or command line arguments"];

    if (SDL_InitSubSystem(SDL_INIT_VIDEO) == -1)
        return self;
    
#if defined(USE_SDL2)
    {
        const int sdlmodes = SDL_GetNumDisplayModes(0);
        for (i = 0; i < sdlmodes; i++)
        {
            SDL_DisplayMode mode;
            if (SDL_GetDisplayMode(0, i, &mode) == 0)
            {
                info = [[ScreenInfo alloc] initWithWidth:mode.w height:mode.h bpp:SDL_BITSPERPIXEL(mode.format)];
                [screenModes addObject:info];
                [info release];
            }
        }
    }
#else
    flags = SDL_OPENGL | SDL_FULLSCREEN;
    format.palette = NULL;
    
    for (i = 0; i < 3; i++) {
        format.BitsPerPixel = bpps[i];
        modes = SDL_ListModes(&format, flags);

        if (modes == (SDL_Rect **)0 || modes == (SDL_Rect **)-1)
            continue;

        for (j = 0; modes[j]; j++) {
            info = [[ScreenInfo alloc] initWithWidth:modes[j]->w height:modes[j]->h bpp:bpps[i]];
            [screenModes addObject:info];
            [info release];
        }
    }
#endif

    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    
    arguments = [[QuakeArguments alloc] initWithArguments:gArgv + 1 count:gArgc - 1];
    return self;
}

- (NSArray *)screenModes {
    return screenModes;
}

#ifndef MAC_OS_X_VERSION_10_13
#define NSControlStateValueOff NSOffState
#define NSControlStateValueOn NSOnState
#endif
- (void)awakeFromNib {
    if ([arguments count] > 0) {
        [paramTextField setStringValue:[arguments description]];
        if ([arguments argument:@"-window"] != nil)
            [fullscreenCheckBox setState:NSControlStateValueOff];
    } else {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

		// PPC port (round v4 §14.6): if NSUserDefaults are unset on
		// fresh install (no FQPrefCommandLineKey), fall back to project
		// defaults instead of empty/zero. The empty-string + zero index
		// + NO fullscreen combination yields a windowed 800x600 launch
		// which doesn't match the per-arch autoexec's 1024x768
		// fullscreen target. Better default: empty cmdline (so autoexec
		// fully controls cvars), fullscreen ON, screen mode = "Default
		// or command line arguments" (index 0) so -width/-height from
		// autoexec aren't overridden by the launcher dropdown.
		NSString *savedCmdLine = [defaults stringForKey:FQPrefCommandLineKey];
		BOOL hasSavedDefaults = (savedCmdLine != nil);

		[paramTextField setStringValue:hasSavedDefaults ? savedCmdLine : @""];

		BOOL fullscreen = hasSavedDefaults
		    ? [defaults boolForKey:FQPrefFullscreenKey]
		    : YES;  // first-launch default: fullscreen ON
		[fullscreenCheckBox setState:fullscreen ? NSControlStateValueOn : NSControlStateValueOff];

		int screenModeIndex = hasSavedDefaults
		    ? [defaults integerForKey:FQPrefScreenModeKey]
		    : 0;  // "Default or command line arguments" -- lets autoexec drive vid_*
		[screenModePopUp selectItemAtIndex:screenModeIndex];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	BOOL forceNoLauncher = ([arguments argument:@"-nolauncher"] != nil);
	if (forceNoLauncher)
		[arguments removeArgument:@"-nolauncher"];

	// `-launcher` forces the settings GUI even without the Option key -- the
	// SSH-testable counterpart to holding Option, and an escape hatch for
	// users who want it every launch. Stripped so it isn't passed to the engine.
	BOOL forceLauncher = ([arguments argument:@"-launcher"] != nil);
	if (forceLauncher)
		[arguments removeArgument:@"-launcher"];

	// Option-key gate: the settings GUI appears only when the user holds Option
	// at startup (or passes -launcher). A plain double-click goes straight into
	// the game so the per-machine autoexec drives the (already-tuned) settings
	// -- idiot-proof default; tweaking is opt-in. GetCurrentKeyModifiers reads
	// the live modifier state (Carbon, available on every target SDK).
	BOOL optionHeld = (GetCurrentKeyModifiers() & optionKey) != 0;
	BOOL showLauncher = (forceLauncher || optionHeld) && !forceNoLauncher;

	if (!showLauncher) {
		// straight-to-game. mark as a bypassed launch so launchQuake skips the
		// NSUserDefaults save (same rationale as -nolauncher: bench/screenshot
		// scripts must not poison the user's saved launcher cmdline).
		bypassedLauncher = YES;
		[self launchQuake:self];
	} else {
		[self showSettingsWindow];
	}
}

- (IBAction)changeScreenMode:(id)sender {
    int index = [screenModePopUp indexOfSelectedItem];
    [fullscreenCheckBox setEnabled:index != 0];
}

- (IBAction)launchQuake:(id)sender {
    [arguments parseArguments:[paramTextField stringValue]];
    
    int index = [screenModePopUp indexOfSelectedItem];
    if (index > 0) {
        ScreenInfo *info = [screenModes objectAtIndex:index];
        
        int width = [info width];
        int height = [info height];
        int bpp = [info bpp];

        [arguments addArgument:@"-width" withValue:[NSString stringWithFormat:@"%d", width]];
        [arguments addArgument:@"-height" withValue:[NSString stringWithFormat:@"%d", height]];
        [arguments addArgument:@"-bpp" withValue:[NSString stringWithFormat:@"%d", bpp]];
    }
    
    [arguments removeArgument:@"-fullscreen"];
    [arguments removeArgument:@"-window"];
    BOOL fullscreen = [fullscreenCheckBox state] == NSControlStateValueOn;
    if (fullscreen)
        [arguments addArgument:@"-fullscreen"];
    else
        [arguments addArgument:@"-window"];

    // update the defaults — but ONLY when the user actually drove the
    // launcher GUI. Bench/screenshot scripts pass -nolauncher and would
    // otherwise overwrite the user's saved cmdline with their own
    // (-noarchautoexec +timedemo demo1 -nosound -width 640 -height 480
    // etc.), poisoning the next manual double-click.
    if (!bypassedLauncher) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:[paramTextField stringValue] forKey:FQPrefCommandLineKey];
        [defaults setObject:[NSNumber numberWithBool:[fullscreenCheckBox state] == NSControlStateValueOn] forKey:FQPrefFullscreenKey];
        [defaults setObject:[NSNumber numberWithInt:index] forKey:FQPrefScreenModeKey];
        [defaults synchronize];
    }

    [self launchCore];
}

// Shared launch tail: chdir to the bundle's parent, hand argv to SDL_main.
// Used by both the legacy NIB launcher and the new settings GUI.
- (void)launchCore {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1040
    NSString *path = [NSString stringWithCString:gArgv[0]];
#else
    NSString *path = [NSString stringWithCString:gArgv[0] encoding:NSASCIIStringEncoding];
#endif
    int i;
    for (i = 0; i < 4; i++)
        path = [path stringByDeletingLastPathComponent];

    [[NSFileManager defaultManager] changeCurrentDirectoryPath:path];

    int argc = [arguments count] + 1;
    char *argv[argc];
    argv[0] = gArgv[0];
    [arguments setArguments:argv + 1];

    [launcherWindow close];
    [settingsWindow close];

    int status = SDL_main (argc, argv);
    exit(status);
}

- (IBAction)cancel:(id)sender {
    exit(0);
}

- (void) dealloc {
    [screenModes release];
    [super dealloc];
}

// ======================================================================
// Settings GUI (Option-gated)
// ======================================================================

// sysctl hw.model -> per-machine autoexec basename (mirror of Quake/host.c).
- (NSString *)machineConfigName {
    char model[64];
    size_t mlen = sizeof(model);
    memset(model, 0, sizeof(model));
    if (sysctlbyname("hw.model", model, &mlen, NULL, 0) != 0 || model[0] == 0)
        return nil;

    static const struct { const char *model; const char *cfg; } map[] = {
        {"PowerMac1,1","autoexec-yosemite"},   {"PowerMac3,1","autoexec-sawtooth"},
        {"PowerMac3,5","autoexec-quicksilver"},{"PowerMac10,1","autoexec-mini-g4"},
        {"Macmini2,1","autoexec-mini-intel"},  {"iMac19,1","autoexec-imac-2019"},
        {"PowerMac8,1","autoexec-imac-g5"},    {"PowerMac8,2","autoexec-imac-g5"},
        {"PowerMac12,1","autoexec-imac-g5"},   {"PowerMac4,2","autoexec-imac-g4"},
        {"PowerMac6,1","autoexec-imac-g4"},    {"PowerMac6,3","autoexec-imac-g4"},
    };
    size_t i;
    for (i = 0; i < sizeof(map)/sizeof(map[0]); i++)
        if (!strcmp(model, map[i].model))
            return [NSString stringWithUTF8String:map[i].cfg];
    return nil;
}

// Parse "cvar value" lines from a bundled .cfg into dict (later files win).
- (void)parseConfig:(NSString *)basename into:(NSMutableDictionary *)dict {
    if (basename == nil)
        return;
    NSString *path = [[NSBundle mainBundle] pathForResource:basename ofType:@"cfg"];
    if (path == nil)
        return;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1040
    NSString *contents = [NSString stringWithContentsOfFile:path];
#else
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
#endif
    if (contents == nil)
        return;

    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSArray *lines = [contents componentsSeparatedByString:@"\n"];
    int li;
    for (li = 0; li < (int)[lines count]; li++) {
        NSString *line = [[lines objectAtIndex:li] stringByTrimmingCharactersInSet:ws];
        if ([line length] == 0 || [line hasPrefix:@"//"])
            continue;
        NSScanner *sc = [NSScanner scannerWithString:line];
        NSString *key = nil, *val = nil;
        if (![sc scanUpToCharactersFromSet:ws intoString:&key])
            continue;
        if (![sc scanUpToCharactersFromSet:ws intoString:&val])
            continue;
        if ([val length] >= 2 && [val hasPrefix:@"\""] && [val hasSuffix:@"\""])
            val = [val substringWithRange:NSMakeRange(1, [val length]-2)];
        [dict setObject:val forKey:key];
    }
}

- (void)loadConfigDefaults {
    if (sgCfgDefaults != nil)
        return;
    sgCfgDefaults = [[NSMutableDictionary alloc] init];

#if defined(QS_ARCH_PPC970)
    NSString *archCfg = @"autoexec-ppc970";
#elif defined(__VEC__) || defined(__ALTIVEC__)
    NSString *archCfg = @"autoexec-ppc7400";
#elif defined(__ppc__) || defined(__POWERPC__) || defined(__powerpc__)
    NSString *archCfg = @"autoexec-ppc750";
#elif defined(__x86_64__) || defined(__amd64__)
    NSString *archCfg = @"autoexec-x86_64";
#else
    NSString *archCfg = nil;
#endif
    [self parseConfig:archCfg into:sgCfgDefaults];              // per-arch baseline
    [self parseConfig:[self machineConfigName] into:sgCfgDefaults]; // machine overlay wins
}

- (NSString *)valueForCvar:(const char *)cvar {
    return [sgCfgDefaults objectForKey:[NSString stringWithUTF8String:cvar]];
}

- (NSTextField *)sgMakeLabel:(NSString *)s frame:(NSRect)f align:(NSTextAlignment)al {
    NSTextField *t = [[NSTextField alloc] initWithFrame:f];
    [t setStringValue:s];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBordered:NO];
    [t setBezeled:NO];
    [t setDrawsBackground:NO];
    [t setAlignment:al];
    [[t cell] setFont:[NSFont systemFontOfSize:11]];
    return [t autorelease];
}

- (void)showSettingsWindow {
    [self loadConfigDefaults];
    sgControls   = [[NSMutableArray alloc] init];
    sgReadouts   = [[NSMutableArray alloc] init];
    sgOrigValues = [[NSMutableArray alloc] init];
    sgItems      = [[NSMutableArray alloc] init];

    const CGFloat W = 540, boxX = 12, boxW = W - 24;
    const CGFloat rowH = 28, topPad = 26, botPad = 12, gap = 14;
    CGFloat y = 10;
    int idx = 0;

    QSFlippedView *doc = [[QSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, 4000)];

    char mdl[64]; size_t ml = sizeof(mdl); mdl[0] = 0;
    sysctlbyname("hw.model", mdl, &ml, NULL, 0);
    NSString *modelStr = (mdl[0]) ? [NSString stringWithUTF8String:mdl] : @"this machine";
    NSTextField *hdr = [self sgMakeLabel:
        [NSString stringWithFormat:@"Defaults are tuned for %@ — tweak below, then Launch. Hover any control for a tip.", modelStr]
        frame:NSMakeRect(boxX, y, boxW, 18) align:NSLeftTextAlignment];
    [doc addSubview:hdr];
    y += 26;

    // --- Display box: resolution + fullscreen --------------------------
    {
        CGFloat boxH = topPad + 2*rowH + botPad;
        NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(boxX, y, boxW, boxH)];
        [box setTitle:@"Display"];
        [box setTitlePosition:NSAtTop];
        [doc addSubview:box];

        CGFloat r0 = y + topPad;
        [doc addSubview:[self sgMakeLabel:@"Resolution" frame:NSMakeRect(boxX+16, r0+3, 170, 18) align:NSLeftTextAlignment]];
        sgScreenModePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxX+196, r0-2, 296, 24) pullsDown:NO];
        int si;
        for (si = 0; si < (int)[screenModes count]; si++)
            [sgScreenModePopUp addItemWithTitle:[[screenModes objectAtIndex:si] description]];
        [sgScreenModePopUp setToolTip:@"Display resolution. 'Default' lets the per-machine config pick."];
        [doc addSubview:sgScreenModePopUp];

        sgFullscreenCheck = [[NSButton alloc] initWithFrame:NSMakeRect(boxX+16, r0+rowH, boxW-40, 20)];
        [sgFullscreenCheck setButtonType:NSSwitchButton];
        [sgFullscreenCheck setTitle:@"Fullscreen"];
        [[sgFullscreenCheck cell] setFont:[NSFont systemFontOfSize:11]];
        [sgFullscreenCheck setState:NSOnState];
        [sgFullscreenCheck setToolTip:@"Run fullscreen (recommended) or in a window."];
        [doc addSubview:sgFullscreenCheck];

        [box release];
        y += boxH + gap;
    }

    // --- cvar sections -------------------------------------------------
    int s;
    for (s = 0; qs_sections[s].title != NULL; s++) {
        const qssection_t *sec = &qs_sections[s];
        int nrows = 0;
        while (sec->items[nrows].cvar != NULL) nrows++;

        CGFloat boxH = topPad + nrows*rowH + botPad;
        NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(boxX, y, boxW, boxH)];
        [box setTitle:[NSString stringWithUTF8String:sec->title]];
        [box setTitlePosition:NSAtTop];
        [doc addSubview:box];

        int r;
        for (r = 0; r < nrows; r++) {
            const qsitem_t *item = &sec->items[r];
            CGFloat ry = y + topPad + r*rowH;
            NSString *cur = [self valueForCvar:item->cvar];
            NSString *tip = [NSString stringWithUTF8String:item->tip];
            NSString *lab = [NSString stringWithUTF8String:item->label];

            if (item->type == QST_CHECK) {
                NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(boxX+16, ry, boxW-40, 20)];
                [b setButtonType:NSSwitchButton];
                [b setTitle:lab];
                [[b cell] setFont:[NSFont systemFontOfSize:11]];
                [b setToolTip:tip];
                BOOL on = (cur != nil) && ([cur doubleValue] != 0.0);
                [b setState: on ? NSOnState : NSOffState];
                [b setTag:idx];
                [doc addSubview:b];
                [sgControls addObject:b];
                [sgReadouts addObject:[NSNull null]];
                [sgOrigValues addObject:(on ? @"1" : @"0")];
                [sgItems addObject:[NSValue valueWithPointer:item]];
                [b release];
            } else if (item->type == QST_SLIDER) {
                [doc addSubview:[self sgMakeLabel:lab frame:NSMakeRect(boxX+16, ry+1, 176, 18) align:NSLeftTextAlignment]];
                NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(boxX+196, ry, 236, 20)];
                [sl setMinValue:item->vmin];
                [sl setMaxValue:item->vmax];
                double v = (cur != nil) ? [cur doubleValue] : item->vmin;
                [sl setDoubleValue:v];
                [sl setContinuous:YES];
                [sl setTarget:self];
                [sl setAction:@selector(sgSliderChanged:)];
                [sl setToolTip:tip];
                [sl setTag:idx];
                [doc addSubview:sl];
                NSString *rs = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                                           : [NSString stringWithFormat:@"%.2f", v];
                NSTextField *ro = [self sgMakeLabel:rs frame:NSMakeRect(boxX+438, ry+1, 60, 18) align:NSRightTextAlignment];
                [doc addSubview:ro];
                [sgControls addObject:sl];
                [sgReadouts addObject:ro];
                [sgOrigValues addObject:rs];
                [sgItems addObject:[NSValue valueWithPointer:item]];
                [sl release];
            } else { // QST_POPUP
                [doc addSubview:[self sgMakeLabel:lab frame:NSMakeRect(boxX+16, ry+3, 176, 18) align:NSLeftTextAlignment]];
                NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxX+196, ry-2, 260, 24) pullsDown:NO];
                [p setToolTip:tip];
                [p setTag:idx];
                int oi, sel = -1;
                NSString *resolved = nil;
                for (oi = 0; item->opts[oi].display != NULL; oi++) {
                    [p addItemWithTitle:[NSString stringWithUTF8String:item->opts[oi].display]];
                    if (cur != nil && strcmp(item->opts[oi].value, [cur UTF8String]) == 0) {
                        sel = oi;
                        resolved = [NSString stringWithUTF8String:item->opts[oi].value];
                    }
                }
                if (sel < 0) {
                    if (cur != nil) { [p addItemWithTitle:cur]; sel = [p numberOfItems]-1; resolved = cur; }
                    else { sel = 0; resolved = [NSString stringWithUTF8String:item->opts[0].value]; }
                }
                [p selectItemAtIndex:sel];
                [doc addSubview:p];
                [sgControls addObject:p];
                [sgReadouts addObject:[NSNull null]];
                [sgOrigValues addObject:resolved];
                [sgItems addObject:[NSValue valueWithPointer:item]];
                [p release];
            }
            idx++;
        }
        [box release];
        y += boxH + gap;
    }

    // --- Advanced box: extra command line ------------------------------
    {
        CGFloat boxH = topPad + rowH + botPad;
        NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(boxX, y, boxW, boxH)];
        [box setTitle:@"Advanced"];
        [box setTitlePosition:NSAtTop];
        [doc addSubview:box];

        CGFloat r0 = y + topPad;
        [doc addSubview:[self sgMakeLabel:@"Extra command line" frame:NSMakeRect(boxX+16, r0+3, 170, 18) align:NSLeftTextAlignment]];
        sgAdvancedField = [[NSTextField alloc] initWithFrame:NSMakeRect(boxX+196, r0, 296, 22)];
        [sgAdvancedField setToolTip:@"Extra engine command-line arguments (advanced)."];
        // Preserve any args we were launched with (mirrors the legacy launcher):
        // parseArguments replaces the whole list, so the field must carry them
        // through. Fall back to the user's saved launcher cmdline otherwise.
        NSString *pre;
        if ([arguments count] > 0) {
            pre = [arguments description];
        } else {
            NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:FQPrefCommandLineKey];
            pre = (saved != nil) ? saved : @"";
        }
        [sgAdvancedField setStringValue:pre];
        [doc addSubview:sgAdvancedField];
        [sgAdvancedField release];

        [box release];
        y += boxH + gap;
    }

    CGFloat docHeight = y;
    [doc setFrame:NSMakeRect(0, 0, W, docHeight)];

    // --- window: scroll view on top, fixed button bar at bottom --------
    CGFloat barH = 48;
    CGFloat visibleDoc = (docHeight < 520) ? docHeight : 520;
    CGFloat winW = W + 18;   // room for the scroller
    CGFloat winH = visibleDoc + barH;

    settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, winW, winH)
        styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask)
        backing:NSBackingStoreBuffered defer:NO];
    [settingsWindow setTitle:@"QuakeSpasm Settings"];
    [settingsWindow setReleasedWhenClosed:NO];
    NSView *content = [settingsWindow contentView];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, barH, winW, visibleDoc)];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:NO];
    [scroll setBorderType:NSNoBorder];
    [scroll setDocumentView:doc];
    [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [content addSubview:scroll];
    // start scrolled to the top of the (flipped) document
    [[scroll contentView] scrollToPoint:NSMakePoint(0, 0)];
    [scroll reflectScrolledClipView:[scroll contentView]];
    [scroll release];
    [doc release];

    NSButton *quit = [[NSButton alloc] initWithFrame:NSMakeRect(12, 10, 90, 28)];
    [quit setTitle:@"Quit"];
    [quit setBezelStyle:NSRoundedBezelStyle];
    [quit setTarget:self];
    [quit setAction:@selector(cancel:)];
    [content addSubview:quit];
    [quit release];

    NSButton *bench = [[NSButton alloc] initWithFrame:NSMakeRect(winW-300, 10, 172, 28)];
    [bench setTitle:@"Run Benchmark"];
    [bench setBezelStyle:NSRoundedBezelStyle];
    [bench setToolTip:@"Run the timedemo benchmark with these settings and write a sysreport to the Desktop (silent)."];
    [bench setTarget:self];
    [bench setAction:@selector(sgRunBenchmark:)];
    [content addSubview:bench];
    [bench release];

    NSButton *play = [[NSButton alloc] initWithFrame:NSMakeRect(winW-122, 10, 110, 28)];
    [play setTitle:@"Launch"];
    [play setBezelStyle:NSRoundedBezelStyle];
    [play setTarget:self];
    [play setAction:@selector(sgLaunch:)];
    [play setKeyEquivalent:@"\r"];
    [content addSubview:play];
    [play release];

    [settingsWindow center];
    [settingsWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)sgSliderChanged:(id)sender {
    int tag = [sender tag];
    id ro = [sgReadouts objectAtIndex:tag];
    if (ro == [NSNull null])
        return;
    const qsitem_t *item = (const qsitem_t *)[[sgItems objectAtIndex:tag] pointerValue];
    double v = [sender doubleValue];
    NSString *s = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                              : [NSString stringWithFormat:@"%.2f", v];
    [(NSTextField *)ro setStringValue:s];
}

// Build the launch argument list from the settings controls: resolution,
// fullscreen, advanced cmdline, and a `+cvar value` override for every
// control the user changed from the per-machine preset.
- (void)sgApplyToArguments {
    [arguments parseArguments:[sgAdvancedField stringValue]];

    int index = [sgScreenModePopUp indexOfSelectedItem];
    if (index > 0) {
        ScreenInfo *info = [screenModes objectAtIndex:index];
        [arguments addArgument:@"-width"  withValue:[NSString stringWithFormat:@"%d",[info width]]];
        [arguments addArgument:@"-height" withValue:[NSString stringWithFormat:@"%d",[info height]]];
        [arguments addArgument:@"-bpp"    withValue:[NSString stringWithFormat:@"%d",[info bpp]]];
    }

    [arguments removeArgument:@"-fullscreen"];
    [arguments removeArgument:@"-window"];
    if ([sgFullscreenCheck state] == NSOnState)
        [arguments addArgument:@"-fullscreen"];
    else
        [arguments addArgument:@"-window"];

    int i, n = [sgControls count];
    for (i = 0; i < n; i++) {
        const qsitem_t *item = (const qsitem_t *)[[sgItems objectAtIndex:i] pointerValue];
        id ctl = [sgControls objectAtIndex:i];
        NSString *orig = [sgOrigValues objectAtIndex:i];
        NSString *cur = nil;
        BOOL changed = NO;

        if (item->type == QST_CHECK) {
            cur = ([ctl state] == NSOnState) ? @"1" : @"0";
            changed = ![cur isEqualToString:orig];
        } else if (item->type == QST_SLIDER) {
            double v = [ctl doubleValue];
            cur = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                              : [NSString stringWithFormat:@"%.2f", v];
            changed = fabs(v - [orig doubleValue]) > 0.0001;
        } else { // QST_POPUP
            NSString *title = [ctl titleOfSelectedItem];
            cur = title;
            int oi;
            for (oi = 0; item->opts[oi].display != NULL; oi++)
                if ([title isEqualToString:[NSString stringWithUTF8String:item->opts[oi].display]]) {
                    cur = [NSString stringWithUTF8String:item->opts[oi].value];
                    break;
                }
            changed = ![cur isEqualToString:orig];
        }

        if (changed) {
            NSString *plus = [@"+" stringByAppendingString:[NSString stringWithUTF8String:item->cvar]];
            [arguments addArgument:plus withValue:cur];
        }
    }
}

- (IBAction)sgLaunch:(id)sender {
    [self sgApplyToArguments];
    [self launchCore];
}

- (IBAction)sgRunBenchmark:(id)sender {
    [self sgApplyToArguments];
    // full 3x3 grid; the engine runs sysreport silent and drops the report
    // (+ console log) on the Desktop.
    [arguments addArgument:@"+sysreport"];
    [self launchCore];
}

@end
