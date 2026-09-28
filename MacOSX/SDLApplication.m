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

#import "SDLApplication.h"

// ericw -- with SDL2, this is unneeded and clashes; it has an SDLApplication class internally which does the same thing
#if !defined(USE_SDL2)

#if defined(SDL_FRAMEWORK) || defined(NO_SDL_CONFIG)
#import <SDL/SDL.h>
#else
#import "SDL.h"
#endif

@implementation SDLApplication
- (void)terminate:(id)sender
{
    /* Post a SDL_QUIT event and let the engine's own main loop quit it
       cleanly (in_sdl.c: SDL_QUIT -> CL_Disconnect -> Sys_Quit ->
       Host_Shutdown -> exit). Do NOT also call [super terminate:sender]:
       that forces AppKit to run its own immediate termination sequence
       (calling exit() from inside NSApplication's own teardown), racing
       the engine's orderly shutdown. On ppc970 G5 hardware that race hit
       AppKit tearing down a Cocoa object SDL's own QZ_UnsetVideoMode then
       dereferenced during SDL_Quit, an EXC_BAD_ACCESS on every quit
       (#74). */
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}
@end

#endif
