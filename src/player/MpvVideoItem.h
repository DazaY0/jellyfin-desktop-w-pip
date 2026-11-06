#ifndef MPVVIDEOITEM_H
#define MPVVIDEOITEM_H

#include <MpvAbstractItem>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QSize>
#include <atomic>
#include <memory>

class PlayerComponent;

class MpvVideoItem : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    ~MpvVideoItem() override;

    Renderer *createRenderer() const override;
    void setPlayerComponent(PlayerComponent* player);

    MpvController* controller() { return mpvController(); }

    void onGlContextCreated(QOpenGLContext* ctx);
    bool isPipActive() const;
    void requestPipFrame();
    void setVideoSize(const QSize& size) { m_videoSize = size; }

private Q_SLOTS:
    void handleMpvRedraw();
    void onPipStateChanged(bool enabled);

private:
    static void onMpvRedrawCallback(void* ctx);
    void initialize();
    void renderOffscreenForPip(bool force);

    PlayerComponent* m_player = nullptr;
    QOpenGLContext* m_glContext = nullptr;
    QOffscreenSurface* m_offscreenSurface = nullptr;
    std::unique_ptr<QOpenGLFramebufferObject> m_offscreenFbo;
    QSize m_videoSize{1280, 720};
    std::atomic<bool> m_redrawPending{false};
    bool m_initialized = false;
    bool m_ready = false;
    bool m_glContextInitialized = false;
};

#endif // MPVVIDEOITEM_H
