#include "MacPiPController.h"
#include "player/PlayerComponent.h"
#include "ui/WindowManager.h"

#include <QDebug>
#include <QtMath>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@class PIPViewController;

@protocol PIPViewControllerDelegate <NSObject>
@optional
- (BOOL)pipShouldClose:(PIPViewController *)pip;
- (void)pipWillClose:(PIPViewController *)pip;
- (void)pipDidClose:(PIPViewController *)pip;
- (void)pipActionPlay:(PIPViewController *)pip;
- (void)pipActionPause:(PIPViewController *)pip;
- (void)pipActionStop:(PIPViewController *)pip;
- (void)pipActionReturn:(PIPViewController *)pip;
- (void)pipAction:(PIPViewController *)pip skipInterval:(double)interval;
@end

@interface PIPViewController : NSViewController
@property (nonatomic, assign, nullable) id<PIPViewControllerDelegate> delegate;
@property (nonatomic, assign, nullable) NSWindow *replacementWindow;
@property (nonatomic) NSRect replacementRect;
@property (nonatomic) bool playing;
@property (nonatomic) bool userCanResize;
@property (nonatomic) NSSize aspectRatio;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)viewController;
@end

@interface MacPiPView : NSView
{
  MacPiPController* m_controller;
}
- (instancetype)initWithFrame:(NSRect)frameRect controller:(MacPiPController*)controller;
@end

@implementation MacPiPView

- (instancetype)initWithFrame:(NSRect)frameRect controller:(MacPiPController*)controller
{
  self = [super initWithFrame:frameRect];
  if (self)
  {
    m_controller = controller;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.autoresizesSubviews = YES;
  }
  return self;
}

- (void)setFrameSize:(NSSize)newSize
{
  [super setFrameSize:newSize];

  CGFloat scale = 2.0;
  if (self.window && self.window.backingScaleFactor > 0.0)
    scale = self.window.backingScaleFactor;
  else if (NSScreen.mainScreen && NSScreen.mainScreen.backingScaleFactor > 0.0)
    scale = NSScreen.mainScreen.backingScaleFactor;

  if (self.layer)
  {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.frame = self.bounds;
    self.layer.contentsScale = scale;
    [CATransaction commit];
  }

  if (m_controller && newSize.width > 0.0 && newSize.height > 0.0)
  {
    int bw = qMax(2, qRound(newSize.width * scale) & ~1);
    int bh = qMax(2, qRound(newSize.height * scale) & ~1);
    m_controller->onPipViewResized(bw, bh);
  }
}

- (void)layout
{
  [super layout];
  if (self.layer)
  {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.frame = self.bounds;
    [CATransaction commit];
  }
}

@end

@interface MacPiPDelegate : NSObject <PIPViewControllerDelegate>
{
  MacPiPController* m_controller;
}
- (instancetype)initWithController:(MacPiPController*)controller;
@end

@implementation MacPiPDelegate

- (instancetype)initWithController:(MacPiPController*)controller
{
  self = [super init];
  if (self)
  {
    m_controller = controller;
  }
  return self;
}

- (BOOL)pipShouldClose:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->updateReplacementGeometry();
  return YES;
}

- (void)pipWillClose:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipWillClose();
}

- (void)pipDidClose:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipDidClose();
}

- (void)pipActionPlay:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipPlay();
}

- (void)pipActionPause:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipPause();
}

- (void)pipActionStop:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipStop();
}

- (void)pipActionReturn:(PIPViewController *)pip
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipReturn();
}

- (void)pipAction:(PIPViewController *)pip skipInterval:(double)interval
{
  Q_UNUSED(pip);
  if (m_controller)
    m_controller->onPipSkipInterval(interval);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////////////
MacPiPController::MacPiPController(PlayerComponent* player)
  : QObject(player), m_player(player)
{
  dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_LAZY);
  Class pipClass = NSClassFromString(@"PIPViewController");
  m_supported = (pipClass != nil);

  if (m_supported)
  {
    m_delegate = [[MacPiPDelegate alloc] initWithController:this];

    MacPiPView* view = [[MacPiPView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360) controller:this];
    view.wantsLayer = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    view.layer.contentsGravity = kCAGravityResizeAspect;
    view.layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    view.layer.opaque = YES;
    m_pipView = view;

    NSViewController* contentVC = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    contentVC.view = view;
    m_contentViewController = contentVC;
  }
  else
  {
    qWarning() << "MacPiPController: PIPViewController not available on this macOS version";
  }

  m_closeFallbackTimer.setSingleShot(true);
  connect(&m_closeFallbackTimer, &QTimer::timeout, this, [this]() {
    if (m_active && m_closing)
    {
      onPipDidClose();
    }
  });
}

///////////////////////////////////////////////////////////////////////////////////////////////////
MacPiPController::~MacPiPController()
{
  endAppNapActivity();
  destroyBuffers();

  if (m_pipViewController)
  {
    auto* pip = static_cast<PIPViewController*>(m_pipViewController);
    pip.delegate = nil;
    [pip release];
    m_pipViewController = nullptr;
  }

  if (m_contentViewController)
  {
    auto* vc = static_cast<NSViewController*>(m_contentViewController);
    [vc release];
    m_contentViewController = nullptr;
  }

  if (m_pipView)
  {
    auto* view = static_cast<NSView*>(m_pipView);
    [view release];
    m_pipView = nullptr;
  }

  if (m_delegate)
  {
    auto* del = static_cast<MacPiPDelegate*>(m_delegate);
    [del release];
    m_delegate = nullptr;
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::setWindow(QQuickWindow* window)
{
  m_window = window;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::setPictureInPictureEnabled(bool enabled)
{
  if (!m_supported)
    return;

  if (enabled)
    enterPiP();
  else
    exitPiP();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::togglePictureInPicture()
{
  setPictureInPictureEnabled(!m_active);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::setPlaying(bool playing)
{
  m_playing = playing;
  if (m_pipViewController)
  {
    auto* pip = static_cast<PIPViewController*>(m_pipViewController);
    [pip setPlaying:playing];
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::setVideoSize(int width, int height)
{
  if (width <= 0 || height <= 0)
    return;

  m_videoSize = QSize(width, height);
  if (m_pipViewController)
  {
    auto* pip = static_cast<PIPViewController*>(m_pipViewController);
    [pip setAspectRatio:NSMakeSize(width, height)];
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
bool MacPiPController::isMainWindowVisibleOnScreen() const
{
  if (!m_window || !m_window->isExposed())
    return false;

  QWindow::Visibility vis = m_window->visibility();
  if (vis == QWindow::Minimized || vis == QWindow::Hidden)
    return false;

  WId wid = m_window->winId();
  if (!wid)
    return false;

  auto* nsView = reinterpret_cast<NSView*>(wid);
  NSWindow* nsWindow = [nsView window];
  if (!nsWindow)
    return false;

  return ([nsWindow occlusionState] & NSWindowOcclusionStateVisible) != 0;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::updateReplacementGeometry()
{
  if (!m_pipViewController)
    return;

  auto* pip = static_cast<PIPViewController*>(m_pipViewController);
  if (!m_window)
  {
    pip.replacementWindow = nil;
    pip.replacementRect = NSZeroRect;
    return;
  }

  WId wid = m_window->winId();
  auto* nsView = reinterpret_cast<NSView*>(wid);
  NSWindow* nsWindow = nsView ? [nsView window] : nil;

  if (nsWindow && (isMainWindowVisibleOnScreen() || m_returningToWindow))
  {
    pip.replacementWindow = nsWindow;
    pip.replacementRect = [nsView bounds];
  }
  else
  {
    pip.replacementWindow = nil;
    pip.replacementRect = NSZeroRect;
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::enterPiP()
{
  if (!m_supported || m_active)
    return;

  Class pipClass = NSClassFromString(@"PIPViewController");
  if (!pipClass)
    return;

  if (m_pipViewController)
  {
    auto* oldPip = static_cast<PIPViewController*>(m_pipViewController);
    oldPip.delegate = nil;
    [oldPip release];
    m_pipViewController = nullptr;
  }

  PIPViewController* pip = [[pipClass alloc] init];
  pip.delegate = static_cast<MacPiPDelegate*>(m_delegate);
  pip.userCanResize = true;
  pip.playing = m_playing;

  int vw = m_videoSize.width() > 0 ? m_videoSize.width() : 1280;
  int vh = m_videoSize.height() > 0 ? m_videoSize.height() : 720;
  pip.aspectRatio = NSMakeSize(vw, vh);

  m_pipViewController = pip;
  m_returningToWindow = false;
  m_closing = false;

  updateReplacementGeometry();

  auto* view = static_cast<NSView*>(m_pipView);
  if ([view superview])
    [view removeFromSuperview];
  view.translatesAutoresizingMaskIntoConstraints = YES;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [view setFrame:NSMakeRect(0, 0, 640, qMax(180, qRound(640.0 * vh / vw)))];

  auto* contentVC = static_cast<NSViewController*>(m_contentViewController);
  contentVC.view = view;

  m_active = true;
  beginAppNapActivity();

  // Populate initial video frame before presenting PiP animation
  if (m_player)
    m_player->requestPipFrame();

  [pip presentViewControllerAsPictureInPicture:contentVC];

  qInfo() << "MacPiPController: Entered Picture-in-Picture mode";
  emit pictureInPictureChanged(true);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::exitPiP()
{
  if (!m_active || m_closing)
    return;

  m_closing = true;
  updateReplacementGeometry();

  auto* pip = static_cast<PIPViewController*>(m_pipViewController);
  auto* contentVC = static_cast<NSViewController*>(m_contentViewController);

  if (pip && contentVC && [contentVC presentingViewController] != nil)
  {
    [pip dismissViewController:contentVC];
    m_closeFallbackTimer.start(700);
  }
  else
  {
    onPipDidClose();
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipViewResized(int backingWidth, int backingHeight)
{
  if (backingWidth <= 0 || backingHeight <= 0)
    return;

  QSize newSize(qBound(320, backingWidth, 1920), qBound(180, backingHeight, 1080));
  newSize.setWidth(newSize.width() & ~1);
  newSize.setHeight(newSize.height() & ~1);

  if (m_pipTargetSize == newSize)
    return;

  m_pipTargetSize = newSize;

  if (m_active && !m_playing && m_player)
    m_player->requestPipFrame();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipWillClose()
{
  m_closing = true;
  updateReplacementGeometry();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipDidClose()
{
  m_closeFallbackTimer.stop();
  endAppNapActivity();

  bool wasActive = m_active;
  m_active = false;
  m_closing = false;
  m_returningToWindow = false;

  if (m_pipViewController)
  {
    auto* pip = static_cast<PIPViewController*>(m_pipViewController);
    pip.delegate = nil;
    [pip release];
    m_pipViewController = nullptr;
  }

  if (wasActive)
  {
    qInfo() << "MacPiPController: Exited Picture-in-Picture mode";
    emit pictureInPictureChanged(false);
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipPlay()
{
  if (m_player)
    m_player->play();
  setPlaying(true);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipPause()
{
  if (m_player)
    m_player->pause();
  setPlaying(false);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipStop()
{
  if (!m_returningToWindow && m_player)
    m_player->pause();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipReturn()
{
  m_returningToWindow = true;
  WindowManager::Get().raiseWindow();
  updateReplacementGeometry();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::onPipSkipInterval(double seconds)
{
  if (!m_player)
    return;

  qint64 currentMs = m_player->getPosition();
  qint64 targetMs = qMax<qint64>(0, currentMs + qRound64(seconds * 1000.0));
  m_player->seekTo(targetMs);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::beginAppNapActivity()
{
  if (m_pipActivity)
    return;

  NSActivityOptions opts = NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled;
  id<NSObject> activity = [[NSProcessInfo processInfo] beginActivityWithOptions:opts
                                                                         reason:@"Jellyfin Picture-in-Picture Playback"];
  m_pipActivity = [activity retain];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::endAppNapActivity()
{
  if (!m_pipActivity)
    return;

  auto* activity = static_cast<id<NSObject>>(m_pipActivity);
  [[NSProcessInfo processInfo] endActivity:activity];
  [activity release];
  m_pipActivity = nullptr;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::ensureBuffers(int width, int height)
{
  CGLContextObj cgl = CGLGetCurrentContext();
  if (!cgl)
    return;

  if (m_cglContext == cgl &&
      m_buffers[0].surface != nullptr &&
      m_buffers[0].width == width &&
      m_buffers[0].height == height)
  {
    return;
  }

  destroyBuffers();
  m_cglContext = cgl;

  GLint prevTex = 0;
  GLint prevFbo = 0;
  glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &prevTex);
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);

  size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, static_cast<size_t>(width) * 4);
  constexpr uint32_t kPixelFormatBGRA = 0x42475241u; // 'BGRA'

  for (int i = 0; i < 2; ++i)
  {
    NSDictionary* props = @{
      reinterpret_cast<id>(const_cast<CFStringRef>(kIOSurfaceWidth)) : @(width),
      reinterpret_cast<id>(const_cast<CFStringRef>(kIOSurfaceHeight)) : @(height),
      reinterpret_cast<id>(const_cast<CFStringRef>(kIOSurfaceBytesPerElement)) : @(4),
      reinterpret_cast<id>(const_cast<CFStringRef>(kIOSurfaceBytesPerRow)) : @(bytesPerRow),
      reinterpret_cast<id>(const_cast<CFStringRef>(kIOSurfacePixelFormat)) : @(kPixelFormatBGRA)
    };

    IOSurfaceRef surf = IOSurfaceCreate(reinterpret_cast<CFDictionaryRef>(props));
    if (!surf)
    {
      qWarning() << "MacPiPController: Failed to create IOSurface";
      continue;
    }

    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_RECTANGLE, tex);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    CGLError err = CGLTexImageIOSurface2D(cgl,
                                          GL_TEXTURE_RECTANGLE,
                                          GL_RGBA8,
                                          width,
                                          height,
                                          GL_BGRA,
                                          GL_UNSIGNED_INT_8_8_8_8_REV,
                                          surf,
                                          0);
    if (err != kCGLNoError)
    {
      qWarning() << "MacPiPController: CGLTexImageIOSurface2D failed with error" << err;
      glDeleteTextures(1, &tex);
      CFRelease(surf);
      continue;
    }

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, tex, 0);

    m_buffers[i].surface = surf;
    m_buffers[i].texture = tex;
    m_buffers[i].fbo = fbo;
    m_buffers[i].width = width;
    m_buffers[i].height = height;
  }

  glBindTexture(GL_TEXTURE_RECTANGLE, static_cast<GLuint>(prevTex));
  glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(prevFbo));
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::destroyBuffers()
{
  CGLContextObj cgl = CGLGetCurrentContext();
  for (int i = 0; i < 2; ++i)
  {
    if (cgl && cgl == m_cglContext)
    {
      if (m_buffers[i].fbo)
        glDeleteFramebuffers(1, &m_buffers[i].fbo);
      if (m_buffers[i].texture)
        glDeleteTextures(1, &m_buffers[i].texture);
    }
    if (m_buffers[i].surface)
    {
      CFRelease(static_cast<IOSurfaceRef>(m_buffers[i].surface));
    }
    m_buffers[i] = PipBuffer{};
  }
  m_cglContext = nullptr;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void MacPiPController::renderFrameFromFbo(unsigned int srcFbo, int width, int height)
{
  if (!m_active || width <= 0 || height <= 0 || !m_pipView)
    return;

  CGLContextObj cgl = CGLGetCurrentContext();
  if (!cgl)
    return;

  QSize dstSize(width, height);
  if (dstSize.width() > 1920 || dstSize.height() > 1080)
    dstSize = dstSize.scaled(1920, 1080, Qt::KeepAspectRatio);

  int dstW = qMax(2, dstSize.width() & ~1);
  int dstH = qMax(2, dstSize.height() & ~1);

  ensureBuffers(dstW, dstH);

  int writeIdx = 1 - m_frontBuffer;
  if (!m_buffers[writeIdx].surface || !m_buffers[writeIdx].fbo)
    return;

  GLint prevReadFbo = 0;
  GLint prevDrawFbo = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevReadFbo);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDrawFbo);

  glBindFramebuffer(GL_READ_FRAMEBUFFER, srcFbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, m_buffers[writeIdx].fbo);

  GLenum filter = (width == dstW && height == dstH) ? GL_NEAREST : GL_LINEAR;
  glBlitFramebuffer(0, 0, width, height,
                    0, 0, dstW, dstH,
                    GL_COLOR_BUFFER_BIT, filter);

  glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(prevReadFbo));
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(prevDrawFbo));
  glFlush();

  m_frontBuffer = writeIdx;
  void* surfaceToDisplay = m_buffers[writeIdx].surface;
  auto* view = static_cast<NSView*>(m_pipView);

  if ([NSThread isMainThread])
  {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.layer.contents = reinterpret_cast<id>(surfaceToDisplay);
    [CATransaction commit];
  }
  else
  {
    CFRetain(static_cast<IOSurfaceRef>(surfaceToDisplay));
    [view retain];
    dispatch_async(dispatch_get_main_queue(), ^{
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      view.layer.contents = reinterpret_cast<id>(surfaceToDisplay);
      [CATransaction commit];
      [view release];
      CFRelease(static_cast<IOSurfaceRef>(surfaceToDisplay));
    });
  }
}

#pragma clang diagnostic pop

