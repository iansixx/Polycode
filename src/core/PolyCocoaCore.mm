/*
 Copyright (C) 2011 by Ivan Safrin
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
*/

#include "polycode/core/PolyCocoaCore.h"
#import "polycode/view/osx/PolycodeView.h"
#include <iostream>
#include <limits.h>
#import <Cocoa/Cocoa.h>

#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include "polycode/core/PolyBasicFileProvider.h"
#include "polycode/core/PolyPhysFSFileProvider.h"

#include <ApplicationServices/ApplicationServices.h>


using namespace Polycode;

void PosixMutex::lock() {
    pthread_mutex_lock(&pMutex);    
}

void PosixMutex::unlock() {
    pthread_mutex_unlock(&pMutex);
}


static bool DisplayModeIs32Bit(CGDisplayModeRef displayMode)
{
	bool is32Bit = false;
	CFStringRef pixelEncoding = CGDisplayModeCopyPixelEncoding(displayMode);
    if(CFStringCompare(pixelEncoding, CFSTR(IO32BitDirectPixels), 0) == kCFCompareEqualTo)
        is32Bit = true;
    CFRelease(pixelEncoding);

	return is32Bit;
}

static CGDisplayModeRef GetBestDisplayModeForParameters(size_t bitsPerPixel, size_t xRes, size_t yRes)
{
	CGDisplayModeRef bestDisplayMode = CGDisplayCopyDisplayMode(CGMainDisplayID());
	size_t bestWidth = CGDisplayModeGetWidth(bestDisplayMode);
	size_t bestHeight = CGDisplayModeGetHeight(bestDisplayMode);
	NSArray* displayModes = (NSArray*)CGDisplayCopyAllDisplayModes(CGMainDisplayID(), NULL);
	for(NSUInteger i = 0; i < [displayModes count]; ++i)
	{
		CGDisplayModeRef candidate = (CGDisplayModeRef)[displayModes objectAtIndex:i];
		size_t candidateWidth  = CGDisplayModeGetWidth(candidate);
		size_t candidateHeight = CGDisplayModeGetHeight(candidate);
		if(!DisplayModeIs32Bit(candidate))
			continue;
		if(candidateWidth >= xRes && candidateWidth < bestWidth
		   && candidateHeight >= yRes && candidateHeight < bestHeight)
		{
			CGDisplayModeRelease(bestDisplayMode);
			bestDisplayMode = candidate;
			bestWidth = candidateWidth;
			bestHeight = candidateHeight;
			CGDisplayModeRetain(bestDisplayMode);
		}
	}
	[displayModes release];
	return bestDisplayMode;
}

long getThreadID() {
	return (long)pthread_self();
}

void Core::getScreenInfo(int *width, int *height, int *hz) {
	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());    

    // Copy the relevant data.
    if (width) *width = CGDisplayModeGetWidth(mode);
    if (height) *height = CGDisplayModeGetHeight(mode);
    if (hz) *hz = CGDisplayModeGetRefreshRate(mode);    
    CGDisplayModeRelease(mode);
}

CocoaCore::CocoaCore(PolycodeView *view, int _xRes, int _yRes, bool fullScreen, bool vSync, int aaLevel, int anisotropyLevel, int frameRate, int monitorIndex, bool retinaSupport) : Core(_xRes, _yRes, fullScreen, vSync, aaLevel, anisotropyLevel, frameRate, monitorIndex) {

    fileProviders.push_back(new BasicFileProvider());
    fileProviders.push_back(new PhysFSFileProvider());
    
    this->retinaSupport = retinaSupport;
    
	hidManager = NULL;
	initGamepad();
	this->fullScreen = false;
	
	eventMutex = createMutex();
	
//	NSLog(@"BUNDLE: %@", [[NSBundle mainBundle] bundlePath]);
	chdir([[[[NSBundle mainBundle] bundlePath] stringByAppendingString:@"/Contents/Resources"] UTF8String]);
	
	defaultWorkingDirectory = String([[[[NSBundle mainBundle] bundlePath] stringByAppendingString:@"/Contents/Resources"] UTF8String]);
	
	userHomeDirectory = String([NSHomeDirectory() UTF8String]);
	
	[view setCore:this];
	
	glView = view;
    
	context = nil;
	
	initTime = mach_absolute_time();					

    renderer = new Renderer();
    
    OpenGLGraphicsInterface *interface = new OpenGLGraphicsInterface();
   // interface->lineSmooth = true;
    renderer->setGraphicsInterface(this, interface);
    services->setRenderer(renderer);
    setVideoMode(xRes, yRes, fullScreen, vSync, aaLevel, anisotropyLevel, retinaSupport);
    
    services->getSoundManager()->setAudioInterface(new PAAudioInterface());
}

void CocoaCore::setVideoMode(int xRes, int yRes, bool fullScreen, bool vSync, int aaLevel, int anisotropyLevel, bool retinaSupport) {
    [[glView window] setContentSize: NSMakeSize(xRes, yRes)];    
    Core::setVideoMode(xRes, yRes, fullScreen, vSync, aaLevel, anisotropyLevel, retinaSupport);
}

void CocoaCore::copyStringToClipboard(const String& str) {

	NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSArray *types = [NSArray arrayWithObjects:NSStringPboardType, nil];
    [pb declareTypes:types owner:nil];
	
	NSString *nsstr = [NSString stringWithCString: str.c_str() encoding:NSUTF8StringEncoding];
    [pb setString: nsstr forType:NSStringPboardType];	
}

String CocoaCore::getClipboardString() {
	NSPasteboard *pb = [NSPasteboard generalPasteboard];		
	NSString* retString = [pb stringForType:NSStringPboardType];
	return [retString UTF8String];
}

Number CocoaCore::getBackingXRes() {
    if(!retinaSupport) {
        return getXRes();
    }
    NSRect backingBounds = [glView convertRectToBacking:[glView bounds]];
    return backingBounds.size.width;
}

Number CocoaCore::getBackingYRes() {
    if(!retinaSupport) {
        return getYRes();
    }
    NSRect backingBounds = [glView convertRectToBacking:[glView bounds]];
    return backingBounds.size.height;
}

void CocoaCore::handleVideoModeChange(VideoModeChangeInfo *modeInfo) {
	this->xRes = modeInfo->xRes;
	this->yRes = modeInfo->yRes;
    this->retinaSupport = modeInfo->retinaSupport;
    
    NSRect backingBounds;
    if(retinaSupport) {
        [glView setWantsBestResolutionOpenGLSurface:YES];
        backingBounds = [glView convertRectToBacking: NSMakeRect(0, 0, xRes, yRes)];
        renderer->setBackingResolutionScale(backingBounds.size.width/xRes, backingBounds.size.height/yRes);
	} else {
        [glView setWantsBestResolutionOpenGLSurface:NO];
        backingBounds.size.width = xRes;
        backingBounds.size.height = yRes;
        renderer->setBackingResolutionScale(1.0, 1.0);
        
    }
    
	bool _wasFullscreen = this->fullScreen;
	this->fullScreen = modeInfo->fullScreen;
	this->aaLevel = modeInfo->aaLevel;
    this->vSync = modeInfo->vSync;
	
	NSOpenGLPixelFormatAttribute attrs[32];
	
	int atindx = 0;
	attrs[atindx++] = NSOpenGLPFADoubleBuffer;
	
	attrs[atindx++] = NSOpenGLPFADepthSize;
	attrs[atindx++] = 32;
	
	if(aaLevel > 0) {
		attrs[atindx++] = NSOpenGLPFASampleBuffers;	
		attrs[atindx++] = 1;	
	
		attrs[atindx++] = NSOpenGLPFASamples;	
		attrs[atindx++] = aaLevel;	
	
		attrs[atindx++] = NSOpenGLPFAMultisample;	
	}
	
	attrs[atindx++] = NSOpenGLPFANoRecovery;		
	
	attrs[atindx++] = NSOpenGLPFAAccelerated;			
	attrs[atindx++] = 0;
	NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];		
		
	if(!format) {
		NSLog(@"Error creating pixel format!\n");
	}
	
	context = [[NSOpenGLContext alloc] initWithFormat: format shareContext:context];
		
	[format release];

	if (context == nil) {
        NSLog(@"Failed to create open gl context");
	}	
		
	[glView clearGLContext];
	[glView setOpenGLContext:context];	
	[context setView: (NSView*)glView];					
		
	renderer->setAnisotropyAmount(anisotropyLevel);
		
	if(fullScreen) {	
		if(monitorIndex > -1) {
			if(monitorIndex > [[NSScreen screens] count]-1) {
				Logger::log("Requested monitor index above available screens.\n");
				monitorIndex = -1;
			}
		}
			
	    if(monitorIndex == -1) {		
			[glView enterFullScreenMode:[[glView window] screen] withOptions: nil];
		} else {
			[glView enterFullScreenMode:[[NSScreen screens] objectAtIndex:monitorIndex] withOptions: nil];
		}
		
		[[glView window] becomeFirstResponder];
	} else {
		if(_wasFullscreen)
			[glView exitFullScreenModeWithOptions: nil];
	}
	
	GLint sync = 0;
	if(vSync) {
		sync =1 ;
	} 
	
	[context setValues:&sync forParameter:NSOpenGLCPSwapInterval];	
				

	CGLContextObj ctx = (CGLContextObj) [context CGLContextObj];
	if(fullScreen) {
		GLint dim[2] = {(GLint)backingBounds.size.width, (GLint)backingBounds.size.height};
		CGLSetParameter(ctx, kCGLCPSurfaceBackingSize, dim);
		CGLEnable (ctx, kCGLCESurfaceBackingSize);
	} else {
		CGLDisable(ctx, kCGLCESurfaceBackingSize);		
	}

	if(aaLevel > 0) {
		glEnable( GL_MULTISAMPLE_ARB );
	} else {
		glDisable( GL_MULTISAMPLE_ARB );			
	}
    
    coreResized = true;
}

void CocoaCore::openFileWithApplication(String file, String application) {
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSString *filePath = [NSString stringWithCString:file.c_str() encoding:NSUTF8StringEncoding];
	NSString *appString = [NSString stringWithCString:application.c_str() encoding:NSUTF8StringEncoding];
		
	[workspace openFile: filePath withApplication: appString andDeactivate: YES];
}

void CocoaCore::launchApplicationWithFile(String application, String file) {
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSURL *url = [NSURL fileURLWithPath: [NSString stringWithCString:application.c_str() encoding:NSUTF8StringEncoding]];

	NSError *error = nil;
	NSArray *arguments = [NSArray arrayWithObjects: [NSString stringWithCString:file.c_str() encoding:NSUTF8StringEncoding], nil];
	[workspace launchApplicationAtURL:url options:0 configuration:[NSDictionary dictionaryWithObject:arguments forKey:NSWorkspaceLaunchConfigurationArguments] error:&error];
//Handle error
}

String CocoaCore::executeExternalCommand(String command,  String args, String inDirectory) {

	String finalCommand = "\""+command+"\" "+args;
	if(inDirectory != "") {
		finalCommand = "cd \""+inDirectory+"\" && "+finalCommand;
	}
	
	
	FILE *fp = popen(finalCommand.c_str(), "r");
	if(!fp) {
		return "Unable to execute command";
	}	
	
	char path[1024];
	String retString;
	
	while (fgets(path, sizeof(path), fp) != NULL) {
		retString = retString + String(path);
	}

	fclose(fp);
	pclose(fp);
	return retString;
}

CocoaCore::~CocoaCore() {
	printf("Shutting down cocoa core\n");
	[glView setCore:nil];	
	shutdownGamepad();
	if(fullScreen) {
		[glView exitFullScreenModeWithOptions:nil];
		
	}
	
	[glView clearGLContext];	
	[context release];
}

void *ManagedThreadFunc(void *data) {
	Threaded *target = static_cast<Threaded*>(data);
	target->runThread();
	target->scheduledForRemoval = true;
	return NULL;
}

void CocoaCore::createThread(Threaded *target) {
	Core::createThread(target);
	pthread_t thread;
	pthread_create( &thread, NULL, ManagedThreadFunc, (void*)target);
}

CoreMutex *CocoaCore::createMutex() {
	PosixMutex *mutex = new PosixMutex();	
	pthread_mutex_init(&mutex->pMutex, NULL);
	return mutex;
}

unsigned int CocoaCore::getTicks() {
	uint64_t time = mach_absolute_time();	
	double conversion = 0.0;
	
	mach_timebase_info_data_t info;
	mach_timebase_info( &info );
	conversion = 1e-9 * (double) info.numer / (double) info.denom;	
	
	return (((double)(time - initTime)) * conversion) * 1000.0f;
}

void CocoaCore::enableMouse(bool newval) {
	
	if(newval) 
		CGDisplayShowCursor(kCGDirectMainDisplay);			
	else
		CGDisplayHideCursor(kCGDirectMainDisplay);	
	Core::enableMouse(newval);
}

void CocoaCore::setCursor(int cursorType) {
	
	NSCursor *newCursor;
	
	switch(cursorType) {
		case CURSOR_TEXT:
			newCursor = [NSCursor IBeamCursor];			
		break;			
		case CURSOR_POINTER:
			newCursor = [NSCursor pointingHandCursor];						
		break;			
		case CURSOR_CROSSHAIR:
			newCursor = [NSCursor crosshairCursor];
		break;			
		case CURSOR_RESIZE_LEFT_RIGHT:
			newCursor = [NSCursor resizeLeftRightCursor];
		break;			
		case CURSOR_RESIZE_UP_DOWN:
			newCursor = [NSCursor resizeUpDownCursor];			
		break;
		case CURSOR_OPEN_HAND:
			newCursor = [NSCursor openHandCursor];			
		break;		
		default:
			newCursor = [NSCursor arrowCursor];			
		break;
	}
	[glView setCurrentCursor:newCursor];
	[glView resetCursorRects];	
	[[glView window] invalidateCursorRectsForView: (NSView*)glView];
}

void CocoaCore::warpCursor(int x, int y) {

	CGSetLocalEventsSuppressionInterval(0);
	NSArray *theScreens = [NSScreen screens];
	for (NSScreen *theScreen in theScreens) {
		CGPoint CenterOfWindow = CGPointMake([glView window].frame.origin.x+x, (-1)*([glView window].frame.origin.y-theScreen.frame.size.height)-yRes+y);
		CGDisplayMoveCursorToPoint (kCGDirectMainDisplay, CenterOfWindow);		
		break;
	}
	lastMouseX = x;
	lastMouseY = y;
}


bool CocoaCore::checkSpecialKeyEvents(PolyKEY key) {
	
	if(key == KEY_a && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER))) {
		dispatchEvent(new Event(), Core::EVENT_SELECT_ALL);
		return true;
	}
	
	if(key == KEY_c && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER))) {
		dispatchEvent(new Event(), Core::EVENT_COPY);
		return true;
	}
	
	if(key == KEY_x && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER))) {
		dispatchEvent(new Event(), Core::EVENT_CUT);
		return true;
	}
	
	
	if(key == KEY_z  && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER)) && (input->getKeyState(KEY_LSHIFT) || input->getKeyState(KEY_RSHIFT))) {
		dispatchEvent(new Event(), Core::EVENT_REDO);
		return true;
	}
		
	if(key == KEY_z  && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER))) {
		dispatchEvent(new Event(), Core::EVENT_UNDO);
		return true;
	}
	
	if(key == KEY_v && (input->getKeyState(KEY_LSUPER) || input->getKeyState(KEY_RSUPER))) {
		dispatchEvent(new Event(), Core::EVENT_PASTE);
		return true;
	}
	return false;
}


void CocoaCore::checkEvents() {
	lockMutex(eventMutex);
	CocoaEvent event;
	for(int i=0; i < cocoaEvents.size(); i++) {
		event = cocoaEvents[i];
		switch(event.eventGroup) {
			case CocoaEvent::INPUT_EVENT:
				switch(event.eventCode) {
					case InputEvent::EVENT_MOUSEMOVE:
						input->setDeltaPosition(lastMouseX - event.mouseX, lastMouseY - event.mouseY);										
						lastMouseX = event.mouseX;
						lastMouseY = event.mouseY;
						input->setMousePosition(event.mouseX, event.mouseY, getTicks());						
						break;
					case InputEvent::EVENT_MOUSEDOWN:
						input->mousePosition.x = event.mouseX;
						input->mousePosition.y = event.mouseY;
						input->setMouseButtonState(event.mouseButton, true, getTicks());						
						break;
					case InputEvent::EVENT_MOUSEWHEEL_UP:
						input->mouseWheelUp(getTicks());
					break;
					case InputEvent::EVENT_MOUSEWHEEL_DOWN:
						input->mouseWheelDown(getTicks());						
					break;						
					case InputEvent::EVENT_MOUSEUP:
						input->setMouseButtonState(event.mouseButton, false, getTicks());
						break;
					case InputEvent::EVENT_KEYDOWN:
						if(!checkSpecialKeyEvents(event.keyCode))
							input->setKeyState(event.keyCode, true, getTicks());
						break;
					case InputEvent::EVENT_KEYUP:
						input->setKeyState(event.keyCode, false, getTicks());
                    break;
                    case InputEvent::EVENT_TOUCHES_BEGAN:
                        input->touchesBegan(event.touch, event.touches, getTicks());
                        break;
                    case InputEvent::EVENT_TOUCHES_ENDED:
                        input->touchesEnded(event.touch, event.touches, getTicks());
                        break;
                    case InputEvent::EVENT_TOUCHES_MOVED:
                        input->touchesMoved(event.touch, event.touches, getTicks());
                    break;
					case InputEvent::EVENT_TEXTINPUT:
						input->textInput(event.text);
					break;
				}
				break;
				case CocoaEvent::FOCUS_EVENT:
					switch(event.eventCode) {
						case Core::EVENT_LOST_FOCUS:
							loseFocus();						
						break;
						case Core::EVENT_GAINED_FOCUS:
							gainFocus();
						break;						
					}
				break;
		}
	}
	cocoaEvents.clear();	
	unlockMutex(eventMutex);		
}

void CocoaCore::openURL(String url) {
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithUTF8String: url.c_str()]]];
}

void CocoaCore::createFolder(const String& folderPath) {
	[[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String: folderPath.c_str()] withIntermediateDirectories:YES attributes:nil error:nil];
}

void CocoaCore::copyDiskItem(const String& itemPath, const String& destItemPath) {
	[[NSFileManager defaultManager] copyItemAtPath: [NSString stringWithUTF8String: itemPath.c_str()] toPath: [NSString stringWithUTF8String: destItemPath.c_str()] error: nil];	
}

void CocoaCore::moveDiskItem(const String& itemPath, const String& destItemPath) {
	[[NSFileManager defaultManager] moveItemAtPath: [NSString stringWithUTF8String: itemPath.c_str()] toPath: [NSString stringWithUTF8String: destItemPath.c_str()] error: nil];		
}

void CocoaCore::removeDiskItem(const String& itemPath) {
	[[NSFileManager defaultManager] removeItemAtPath: [NSString stringWithUTF8String: itemPath.c_str()] error:nil];
}

void CocoaCore::makeApplicationMain() {
	[NSApp activateIgnoringOtherApps:YES];
}
	
String CocoaCore::openFolderPicker() {
	unlockMutex(eventMutex);
	NSOpenPanel *attachmentPanel = [[NSOpenPanel openPanel] retain];
	[attachmentPanel setCanChooseFiles:NO];
	[attachmentPanel setCanCreateDirectories: YES];
	[attachmentPanel setCanChooseDirectories:YES];
	
	if ( [attachmentPanel runModal] == NSOKButton )
	{
		// files and directories selected.
		NSURL* url = [attachmentPanel URL];
		[attachmentPanel release];
		return [[url path] UTF8String];
	} else {
		[attachmentPanel release];	
		return [@"" UTF8String];
	}	
}

String CocoaCore::saveFilePicker(std::vector<CoreFileExtension> extensions) {
	unlockMutex(eventMutex);	    
    String retString;
  	NSSavePanel *attachmentPanel = [NSSavePanel savePanel];
    
	[attachmentPanel setCanCreateDirectories: YES];

	NSMutableArray *types = nil;
    
	if(extensions.size() > 0) {
		types = [[NSMutableArray alloc] init];
		for(int i=0; i < extensions.size(); i++) {
			CoreFileExtension extInfo = extensions[i];
			[types addObject: [NSString stringWithUTF8String: extInfo.extension.c_str()]];
		}
	}
	[attachmentPanel setAllowedFileTypes:types];
    
	if ( [attachmentPanel runModal] == NSOKButton )
	{
		NSURL* url = [attachmentPanel URL];
        if(url) {
            NSString* fileName = [url path];
            retString = [fileName UTF8String];
		}
	}
    
    return retString;
}

vector<String> CocoaCore::openFilePicker(vector<CoreFileExtension> extensions, bool allowMultiple) {
	unlockMutex(eventMutex);	
	vector<String> retVector;
	
	NSOpenPanel *attachmentPanel = [NSOpenPanel openPanel];	
	[attachmentPanel setCanChooseFiles:YES];
	[attachmentPanel setCanCreateDirectories: YES];
	[attachmentPanel setCanChooseDirectories:NO];
	[attachmentPanel setAllowsMultipleSelection: allowMultiple];
	
	NSMutableArray *types = nil;

	if(extensions.size() > 0) {
		types = [[NSMutableArray alloc] init];	
		for(int i=0; i < extensions.size(); i++) {	
			CoreFileExtension extInfo = extensions[i];
			[types addObject: [NSString stringWithUTF8String: extInfo.extension.c_str()]];
		}
	}
	
	[attachmentPanel setAllowedFileTypes:types];
	if ( [attachmentPanel runModal] == NSOKButton )
	{
		NSArray* files = [attachmentPanel URLs];
	
		if(files) {
			for (int i=0; i < [files count]; i++) {		
				NSURL* url = [files objectAtIndex:i];
				NSString* fileName = [url path];
				retVector.push_back([fileName UTF8String]);
			}
		}
	}
	
	return retVector;
}

void CocoaCore::flushRenderContext() {
    [context flushBuffer];
}

bool CocoaCore::systemUpdate() {
	if(!running)
		return false;
	doSleep();
							
	updateCore();
	checkEvents();
	return running;
}

static void hatValueToXY(CFIndex value, CFIndex range, int * outX, int * outY) {
	if (value == range) {
		*outX = *outY = 0;
		
	} else {
		if (value > 0 && value < range / 2) {
			*outX = 1;
			
		} else if (value > range / 2) {
			*outX = -1;
			
		} else {
			*outX = 0;
		}
		
		if (value > range / 4 * 3 || value < range / 4) {
			*outY = -1;
			
		} else if (value > range / 4 && value < range / 4 * 3) {
			*outY = 1;
			
		} else {
			*outY = 0;
		}
	}
}


// Marked as unused to avoid a warning, assuming that this is useful for debugging.
__attribute__((unused))
static int IOHIDDeviceGetIntProperty(IOHIDDeviceRef deviceRef, CFStringRef key) {
	CFTypeRef typeRef;
	int value;
	
	typeRef = IOHIDDeviceGetProperty(deviceRef, key);
	if (typeRef == NULL || CFGetTypeID(typeRef) != CFNumberGetTypeID()) {
		return 0;
	}
	
	CFNumberGetValue((CFNumberRef) typeRef, kCFNumberSInt32Type, &value);
	return value;
}	

static void onDeviceValueChanged(void * context, IOReturn result, void * sender, IOHIDValueRef value) {
	IOHIDElementRef element;
	IOHIDElementCookie cookie;
	unsigned int axisIndex, buttonIndex;
	static mach_timebase_info_data_t timebaseInfo;
	
	if (timebaseInfo.denom == 0) {
		mach_timebase_info(&timebaseInfo);
	}
	
	GamepadDeviceEntry *deviceRecord = (GamepadDeviceEntry*) context;
	CoreInput *input = deviceRecord->input;
	JoystickInfo *joystickInfo = input->getJoystickInfoByID(deviceRecord->deviceID);
	if(!joystickInfo)
		return;
	
	element = IOHIDValueGetElement(value);
	cookie = IOHIDElementGetCookie(element);
	
	for (axisIndex = 0; axisIndex < deviceRecord->numAxes; axisIndex++) {
		if (!deviceRecord->axisElements[axisIndex].isHatSwitchSecondAxis &&
		    deviceRecord->axisElements[axisIndex].cookie == cookie) {
			CFIndex integerValue;
			
			if (IOHIDValueGetLength(value) > 4) {
				// Workaround for a strange crash that occurs with PS3 controller; was getting lengths of 39 (!)
				continue;
			}
			integerValue = IOHIDValueGetIntegerValue(value);
			
			if (deviceRecord->axisElements[axisIndex].isHatSwitch) {
				int x, y;
				
				// Fix for Saitek X52
				deviceRecord->axisElements[axisIndex].hasNullState = false;
				if (!deviceRecord->axisElements[axisIndex].hasNullState) {
					if (integerValue < deviceRecord->axisElements[axisIndex].logicalMin) {
						integerValue = deviceRecord->axisElements[axisIndex].logicalMax - deviceRecord->axisElements[axisIndex].logicalMin + 1;
					} else {
						integerValue--;
					}
				}
				
				hatValueToXY(integerValue, deviceRecord->axisElements[axisIndex].logicalMax - deviceRecord->axisElements[axisIndex].logicalMin + 1, &x, &y);
				
				if (x != joystickInfo->joystickAxisState[axisIndex]) {
					input->joystickAxisMoved(axisIndex, x, deviceRecord->deviceID);
				}
				
				if (y != joystickInfo->joystickAxisState[axisIndex + 1]) {
					input->joystickAxisMoved(axisIndex + 1, y, deviceRecord->deviceID);				
				}				
			} else {
				float floatValue;
				
				if (integerValue < deviceRecord->axisElements[axisIndex].logicalMin) {
					deviceRecord->axisElements[axisIndex].logicalMin = integerValue;
				}
				if (integerValue > deviceRecord->axisElements[axisIndex].logicalMax) {
					deviceRecord->axisElements[axisIndex].logicalMax = integerValue;
				}
				
				floatValue = (integerValue - deviceRecord->axisElements[axisIndex].logicalMin) / (float) (deviceRecord->axisElements[axisIndex].logicalMax - deviceRecord->axisElements[axisIndex].logicalMin) * 2.0f - 1.0f;
				input->joystickAxisMoved(axisIndex, floatValue, deviceRecord->deviceID);
			}
			
			return;
		}
	}
	
	for (buttonIndex = 0; buttonIndex < deviceRecord->numButtons; buttonIndex++) {
		if (deviceRecord->buttonElements[buttonIndex].cookie == cookie) {
			bool down;
			
			down = IOHIDValueGetIntegerValue(value);
			if(down) {
				input->joystickButtonDown(buttonIndex, deviceRecord->deviceID);
			} else {
				input->joystickButtonUp(buttonIndex, deviceRecord->deviceID);			
			}
			return;
		}
	}
}

bool CocoaCore::systemParseFolder(const Polycode::String& pathString, bool showHidden, std::vector<OSFileEntry> &targetVector) {


    DIR           *d;
    struct dirent *dir;
    
    d = opendir(pathString.c_str());
    if(d) {
        while ((dir = readdir(d)) != NULL) {
            if(dir->d_name[0] != '.' || (dir->d_name[0] == '.'  && showHidden)) {
                if(dir->d_type == DT_DIR) {
                    targetVector.push_back(OSFileEntry(pathString, dir->d_name, OSFileEntry::TYPE_FOLDER));
                } else {
                    targetVector.push_back(OSFileEntry(pathString, dir->d_name, OSFileEntry::TYPE_FILE));
                }
            }
        }
        closedir(d);
    }
    return true;
}

static void onDeviceMatched(void * context, IOReturn result, void * sender, IOHIDDeviceRef device) {
	CocoaCore *core = (CocoaCore*) context;

CFArrayRef elements;
	CFIndex elementIndex;
	IOHIDElementRef element;
	IOHIDElementType type;
	
	GamepadDeviceEntry *entry = new GamepadDeviceEntry();
	entry->device = device;
	entry->input  = core->getInput();
    entry->numButtons = 0;
    entry->numAxes = 0;
    
	entry->deviceID = core->nextDeviceID++;
	core->gamepads.push_back(entry);	
	core->getInput()->addJoystick(entry->deviceID);
	
	elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
	for (elementIndex = 0; elementIndex < CFArrayGetCount(elements); elementIndex++) {
		element = (IOHIDElementRef) CFArrayGetValueAtIndex(elements, elementIndex);
		type = IOHIDElementGetType(element);
		
		// All of the axis elements I've ever detected have been kIOHIDElementTypeInput_Misc. kIOHIDElementTypeInput_Axis is only included for good faith...
		if (type == kIOHIDElementTypeInput_Misc ||
		    type == kIOHIDElementTypeInput_Axis) {

			entry->axisElements.resize(entry->numAxes+1);
			entry->axisElements[entry->numAxes].cookie = IOHIDElementGetCookie(element);
			entry->axisElements[entry->numAxes].logicalMin = IOHIDElementGetLogicalMin(element);
			entry->axisElements[entry->numAxes].logicalMax = IOHIDElementGetLogicalMax(element);
			entry->axisElements[entry->numAxes].hasNullState = !!IOHIDElementHasNullState(element);
			entry->axisElements[entry->numAxes].isHatSwitch = IOHIDElementGetUsage(element) == kHIDUsage_GD_Hatswitch;
			entry->axisElements[entry->numAxes].isHatSwitchSecondAxis = false;
			entry->numAxes++;
			
			if (entry->axisElements[entry->numAxes - 1].isHatSwitch) {
				entry->axisElements.resize(entry->numAxes+1);			
				entry->axisElements[entry->numAxes].isHatSwitchSecondAxis = true;
				entry->numAxes++;
			}			
		} else if (type == kIOHIDElementTypeInput_Button) {
			entry->buttonElements.resize(entry->numButtons+1);			
			entry->buttonElements[entry->numButtons].cookie = IOHIDElementGetCookie(element);
			entry->numButtons++;
		}
	}
	CFRelease(elements);
		
	IOHIDDeviceRegisterInputValueCallback(device, onDeviceValueChanged, entry);
	
}

static void onDeviceRemoved(void * context, IOReturn result, void * sender, IOHIDDeviceRef device) {
	CocoaCore *core = (CocoaCore*) context;	
	for(int i=0; i < core->gamepads.size();i++) {
		if(core->gamepads[i]->device == device) {
			core->getInput()->removeJoystick(core->gamepads[i]->deviceID);
			delete core->gamepads[i];
			core->gamepads.erase(core->gamepads.begin()+i);
			IOHIDDeviceRegisterInputValueCallback(device, NULL, NULL);
			return;
		}
	}
}

void CocoaCore::shutdownGamepad() {
	if (hidManager != NULL) {
		
        
        for (int i = 0; i < gamepads.size(); i++) {
            IOHIDDeviceRegisterInputValueCallback(gamepads[i]->device, NULL, NULL);
            delete gamepads[i];
        }
        
        
		IOHIDManagerRegisterDeviceMatchingCallback(hidManager, NULL, NULL);
		IOHIDManagerRegisterDeviceRemovalCallback(hidManager, NULL, NULL);		
		
		IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		IOHIDManagerClose(hidManager, 0);
		CFRelease(hidManager);
		hidManager = NULL;

		
	}
}

void CocoaCore::initGamepad() {
	if (hidManager == NULL) {
		nextDeviceID = 0;
		CFStringRef keys[2];
		int value;
		CFNumberRef values[2];
		CFDictionaryRef dictionaries[3];
		CFArrayRef array;
		
		hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
		IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone);
		IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		
		keys[0] = CFSTR(kIOHIDDeviceUsagePageKey);
		keys[1] = CFSTR(kIOHIDDeviceUsageKey);
		
		value = kHIDPage_GenericDesktop;
		values[0] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		value = kHIDUsage_GD_Joystick;
		values[1] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		dictionaries[0] = CFDictionaryCreate(kCFAllocatorDefault, (const void **) keys, (const void **) values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFRelease(values[0]);
		CFRelease(values[1]);
		
		value = kHIDPage_GenericDesktop;
		values[0] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		value = kHIDUsage_GD_GamePad;
		values[1] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		dictionaries[1] = CFDictionaryCreate(kCFAllocatorDefault, (const void **) keys, (const void **) values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFRelease(values[0]);
		CFRelease(values[1]);
		
		value = kHIDPage_GenericDesktop;
		values[0] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		value = kHIDUsage_GD_MultiAxisController;
		values[1] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		dictionaries[2] = CFDictionaryCreate(kCFAllocatorDefault, (const void **) keys, (const void **) values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFRelease(values[0]);
		CFRelease(values[1]);
		
		array = CFArrayCreate(kCFAllocatorDefault, (const void **) dictionaries, 3, &kCFTypeArrayCallBacks);
		CFRelease(dictionaries[0]);
		CFRelease(dictionaries[1]);
		CFRelease(dictionaries[2]);
		IOHIDManagerSetDeviceMatchingMultiple(hidManager, array);
		CFRelease(array);
		
		IOHIDManagerRegisterDeviceMatchingCallback(hidManager, onDeviceMatched, this);
		IOHIDManagerRegisterDeviceRemovalCallback(hidManager, onDeviceRemoved, this);
	}
}
