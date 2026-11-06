#include "MpvVideoItem.h"
#include "PlayerComponent.h"
#include "mpvabstractitem_p.h"
#include "mpvrenderer.h"
#include <MpvController>
#include <QDebug>
#include <QOpenGLFunctions>
#include <QQuickWindow>
#include <QThread>

namespace
{
class MpvPipRenderer : public MpvRenderer
{
public:
    explicit MpvPipRenderer(MpvVideoItem *item)
        : MpvRenderer(item), m_videoItem(item)
    {
    }

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        QOpenGLFramebufferObject *fbo = MpvRenderer::createFramebufferObject(size);
        m_videoItem->onGlContextCreated(QOpenGLContext::currentContext());
        return fbo;
    }

    void render() override
    {
        if (m_videoItem->isPipActive()) {
            // Block video rendering in the normal player while PiP is active
            QOpenGLFramebufferObject *fbo = framebufferObject();
            if (fbo) {
                fbo->bind();
                QOpenGLContext *ctx = QOpenGLContext::currentContext();
                QOpenGLFunctions *funcs = ctx ? ctx->functions() : nullptr;
                if (funcs) {
                    funcs->glViewport(0, 0, fbo->width(), fbo->height());
                    funcs->glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
                    funcs->glClear(GL_COLOR_BUFFER_BIT);
                }
            }
            return;
        }

        MpvRenderer::render();
    }

private:
    MpvVideoItem *m_videoItem = nullptr;
};
} // namespace

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : MpvAbstractItem(parent)
{
    connect(this, &MpvAbstractItem::ready, this, [this]() {
        qDebug() << "MpvVideoItem ready() signal fired!";
        m_ready = true;
        initialize();
    });

    qDebug() << "MpvVideoItem constructed";
    // Critical: Set vo=libmpv for Qt integration
    Q_EMIT setProperty("vo", "libmpv");

#ifdef Q_OS_WIN32
    // Force desktop OpenGL and disable advanced features for compatibility with older GPUs
    Q_EMIT setProperty("gpu-api", "opengl");
    Q_EMIT setProperty("opengl-es", "no");
#endif
}

MpvVideoItem::~MpvVideoItem()
{
    if (m_offscreenFbo) {
        if (m_glContext && m_glContext->thread() == QThread::currentThread()) {
            QSurface *targetSurface = window() ? static_cast<QSurface *>(window())
                                               : static_cast<QSurface *>(m_offscreenSurface);
            if (targetSurface && m_glContext->makeCurrent(targetSurface)) {
                m_offscreenFbo.reset();
                m_glContext->doneCurrent();
            } else {
                m_offscreenFbo.release();
            }
        } else {
            m_offscreenFbo.release();
        }
    }
    delete m_offscreenSurface;
    m_offscreenSurface = nullptr;
}

QQuickFramebufferObject::Renderer *MpvVideoItem::createRenderer() const
{
    return new MpvPipRenderer(const_cast<MpvVideoItem *>(this));
}

void MpvVideoItem::onGlContextCreated(QOpenGLContext *ctx)
{
    if (m_glContextInitialized || !ctx)
        return;

    m_glContextInitialized = true;
    m_glContext = ctx;

    if (d_ptr && d_ptr->m_mpv_gl) {
        mpv_render_context_set_update_callback(d_ptr->m_mpv_gl, &MpvVideoItem::onMpvRedrawCallback, this);
    }

    if (!m_offscreenSurface && QThread::currentThread() == thread()) {
        m_offscreenSurface = new QOffscreenSurface();
        m_offscreenSurface->setFormat(ctx->format());
        m_offscreenSurface->create();
    }
}

bool MpvVideoItem::isPipActive() const
{
#ifdef Q_OS_MAC
    return m_player && m_player->isPictureInPictureEnabled();
#else
    return false;
#endif
}

void MpvVideoItem::onMpvRedrawCallback(void *ctx)
{
    auto *item = static_cast<MpvVideoItem *>(ctx);
    if (!item->m_redrawPending.exchange(true)) {
        QMetaObject::invokeMethod(item, &MpvVideoItem::handleMpvRedraw, Qt::QueuedConnection);
    }
}

void MpvVideoItem::handleMpvRedraw()
{
    m_redrawPending.store(false);
#ifdef Q_OS_MAC
    if (isPipActive()) {
        renderOffscreenForPip(false);
        return;
    }
#endif
    update();
}

void MpvVideoItem::onPipStateChanged(bool enabled)
{
#ifdef Q_OS_MAC
    // When rendering directly to PiP on the GUI thread, setting video-timing-offset to 0
    // lets libmpv's background VO thread pace frames without blocking the GUI event loop.
    Q_EMIT setProperty("video-timing-offset", enabled ? 0.0 : 0.05);
#else
    Q_UNUSED(enabled);
#endif
    // Trigger a scene-graph update so the main window either clears to black (on PiP enter)
    // or resumes rendering the video in the normal player (on PiP exit).
    update();
}

void MpvVideoItem::requestPipFrame()
{
#ifdef Q_OS_MAC
    renderOffscreenForPip(true);
#endif
    update();
}

void MpvVideoItem::renderOffscreenForPip(bool force)
{
#ifdef Q_OS_MAC
    if (!isPipActive())
        return;
    if (!d_ptr || !d_ptr->m_mpv_gl || !m_glContext)
        return;
    if (m_glContext->thread() != QThread::currentThread())
        return;

    QOpenGLContext *prevCtx = QOpenGLContext::currentContext();
    QSurface *prevSurface = prevCtx ? prevCtx->surface() : nullptr;

    // Prefer binding m_glContext to its existing QQuickWindow surface so QCocoaGLContext
    // does not detach or rebind the NSOpenGLContext drawable view.
    QSurface *targetSurface = window() ? static_cast<QSurface *>(window())
                                       : static_cast<QSurface *>(m_offscreenSurface);
    if (!targetSurface)
        return;

    bool switchedContext = false;
    if (prevCtx != m_glContext || prevSurface != targetSurface) {
        if (!m_glContext->makeCurrent(targetSurface)) {
            if (!m_offscreenSurface || !m_glContext->makeCurrent(m_offscreenSurface))
                return;
        }
        switchedContext = true;
    }

    auto restoreContext = [&]() {
        if (!switchedContext)
            return;
        if (prevCtx && prevSurface) {
            prevCtx->makeCurrent(prevSurface);
        } else {
            m_glContext->doneCurrent();
        }
    };

    uint64_t flags = mpv_render_context_update(d_ptr->m_mpv_gl);
    if (!force && !(flags & MPV_RENDER_UPDATE_FRAME)) {
        restoreContext();
        return;
    }

    QSize pipBounds = m_player ? m_player->pipTargetSize() : QSize(1280, 720);
    if (!pipBounds.isValid() || pipBounds.isEmpty())
        pipBounds = QSize(1280, 720);

    QSize targetSize = (m_videoSize.isValid() && !m_videoSize.isEmpty())
                           ? m_videoSize.scaled(pipBounds, Qt::KeepAspectRatio)
                           : pipBounds;
    if (targetSize.width() > 1920 || targetSize.height() > 1080) {
        targetSize = targetSize.scaled(1920, 1080, Qt::KeepAspectRatio);
    }
    targetSize.setWidth(qMax(2, targetSize.width() & ~1));
    targetSize.setHeight(qMax(2, targetSize.height() & ~1));

    if (!m_offscreenFbo || m_offscreenFbo->size() != targetSize) {
        m_offscreenFbo = std::make_unique<QOpenGLFramebufferObject>(targetSize);
    }

    mpv_opengl_fbo mpfbo;
    mpfbo.fbo = static_cast<int>(m_offscreenFbo->handle());
    mpfbo.w = m_offscreenFbo->width();
    mpfbo.h = m_offscreenFbo->height();
    mpfbo.internal_format = 0;

    int flip_y = 0;
    int block_for_target_time = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &mpfbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time},
        {MPV_RENDER_PARAM_INVALID, nullptr}
    };

    mpv_render_context_render(d_ptr->m_mpv_gl, params);
    m_player->renderPipFrame(m_offscreenFbo->handle(), m_offscreenFbo->width(), m_offscreenFbo->height());

    restoreContext();
#else
    Q_UNUSED(force);
#endif
}

void MpvVideoItem::setPlayerComponent(PlayerComponent* player)
{
    qDebug() << "MpvVideoItem::setPlayerComponent called, mpvController():" << mpvController();
    if (m_player) {
        disconnect(m_player, &PlayerComponent::pictureInPictureChanged, this, &MpvVideoItem::onPipStateChanged);
    }
    m_player = player;
    if (m_player) {
        connect(m_player, &PlayerComponent::pictureInPictureChanged, this, &MpvVideoItem::onPipStateChanged);
    }
    initialize();
}

void MpvVideoItem::initialize() {
    if (m_initialized) {
        qDebug() << "MpvVideoItem is already initialized, ignoring";
        return;
    }

    if (!m_ready) {
        qDebug() << "MpvVideoItem not ready yet, waiting for ready() signal";
        return;
    }

    if (!m_player) {
        qDebug() << "MpvVideoItem has no player, waiting for setPlayerComponent()";
        return;
    }

    m_initialized = true;

    qDebug() << "MpvVideoItem ready, initializing now";
    m_player->setMpvController(mpvController());
    m_player->initializeMpv();
}
