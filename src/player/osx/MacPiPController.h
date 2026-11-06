#ifndef MACPIPCONTROLLER_H
#define MACPIPCONTROLLER_H

#include <QObject>
#include <QQuickWindow>
#include <QSize>
#include <QTimer>

class PlayerComponent;

class MacPiPController : public QObject
{
  Q_OBJECT

public:
  explicit MacPiPController(PlayerComponent* player);
  ~MacPiPController() override;

  bool isSupported() const { return m_supported; }
  bool isActive() const { return m_active; }

  void setWindow(QQuickWindow* window);
  void setPictureInPictureEnabled(bool enabled);
  void togglePictureInPicture();

  void setPlaying(bool playing);
  void setVideoSize(int width, int height);

  bool isMainWindowVisibleOnScreen() const;
  QSize pipTargetSize() const { return m_pipTargetSize; }
  void renderFrameFromFbo(unsigned int srcFbo, int width, int height);

  // Delegate / view callbacks
  void onPipViewResized(int backingWidth, int backingHeight);
  void onPipWillClose();
  void onPipDidClose();
  void onPipPlay();
  void onPipPause();
  void onPipStop();
  void onPipReturn();
  void onPipSkipInterval(double seconds);
  void updateReplacementGeometry();

Q_SIGNALS:
  void pictureInPictureChanged(bool enabled);

private:
  void enterPiP();
  void exitPiP();
  void ensureBuffers(int width, int height);
  void destroyBuffers();
  void beginAppNapActivity();
  void endAppNapActivity();

  struct PipBuffer
  {
    void* surface = nullptr; // IOSurfaceRef
    unsigned int texture = 0;
    unsigned int fbo = 0;
    int width = 0;
    int height = 0;
  };

  PlayerComponent* m_player = nullptr;
  QQuickWindow* m_window = nullptr;

  void* m_pipViewController = nullptr;     // PIPViewController*
  void* m_contentViewController = nullptr; // NSViewController*
  void* m_pipView = nullptr;               // NSView*
  void* m_delegate = nullptr;              // MacPiPDelegate*
  void* m_pipActivity = nullptr;           // id<NSObject>
  void* m_cglContext = nullptr;            // CGLContextObj

  PipBuffer m_buffers[2];
  int m_frontBuffer = 0;

  QSize m_videoSize{1280, 720};
  QSize m_pipTargetSize{1280, 720};
  bool m_supported = false;
  bool m_active = false;
  bool m_closing = false;
  bool m_returningToWindow = false;
  bool m_playing = false;

  QTimer m_closeFallbackTimer;
};

#endif // MACPIPCONTROLLER_H

