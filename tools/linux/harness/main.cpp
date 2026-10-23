// qml-shot harness: load one QML file, render it once without a display, save
// a PNG and print one machine-readable evidence line. Driven by tools/qml-shot.sh.
//
// Two render modes:
//   rhi     QQuickRenderControl + RHI offscreen frame into a texture. This is
//           the only mode where ShaderEffect actually executes on macOS: the
//           offscreen QPA plugin forces the software scenegraph backend, and
//           the software backend does not draw ShaderEffect items at all.
//   window  plain QQuickWindow grabWindow(). Works on every platform and
//           backend, including the software backend, so it is fine for layout
//           and typography stills but not for shaders.
//
//   QML_SHOT_MODE=auto|rhi|window   (default auto: rhi, falling back to window)
//
// Contract:
//   qml-shot-harness <in.qml> <out.png> [width height]
//   - the root object is an Item (resized to width x height) or a Window (its
//     direct content items are moved into the grab window at the same size);
//     anything else exits 2 with a message.
//   - the background is opaque black, so captures without alpha are stable.
//   - exit 0 shot saved, 1 grab/save failed, 2 QML load failed or unsupported
//     root, 64 usage.
//
// stdout (one line, key=value):
//   qt=<version> platform=<qpa> mode=rhi|window api=<rhi api> capture=<how>
//   root=item|window frames=<n> image=<w>x<h> distinct=<n> minlum=<0-255>
//   maxlum=<0-255> center=#rrggbb corner=#rrggbb saved=<abs path>

// vulkan.h first: Qt's QVulkanInstance pulls in qvulkanfunctions.h, which
// defines VK_NO_PROTOTYPES and would hide vkCreateInstance.
#include <vulkan/vulkan.h>

#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <rhi/qrhi.h>
#include <QSGRendererInterface>
#include <QSet>
#include <QTimer>
#include <QUrl>
#include <QVulkanInstance>

#include <atomic>
#include <cmath>
#include <cstdio>

namespace {

QString gGpuName;

QString apiName(QSGRendererInterface::GraphicsApi api)
{
    switch (api) {
    case QSGRendererInterface::Metal:
        return QStringLiteral("metal");
    case QSGRendererInterface::OpenGL:
        return QStringLiteral("opengl");
    case QSGRendererInterface::Vulkan:
        return QStringLiteral("vulkan");
    case QSGRendererInterface::Direct3D11:
        return QStringLiteral("d3d11");
    case QSGRendererInterface::Direct3D12:
        return QStringLiteral("d3d12");
    case QSGRendererInterface::Software:
        return QStringLiteral("software");
    case QSGRendererInterface::Null:
        return QStringLiteral("null");
    default:
        return QStringLiteral("unknown");
    }
}

QString rhiApiName(QRhi::Implementation impl)
{
    switch (impl) {
    case QRhi::Metal:
        return QStringLiteral("metal");
    case QRhi::OpenGLES2:
        return QStringLiteral("opengl");
    case QRhi::Vulkan:
        return QStringLiteral("vulkan");
    case QRhi::D3D11:
        return QStringLiteral("d3d11");
    case QRhi::D3D12:
        return QStringLiteral("d3d12");
    case QRhi::Null:
        return QStringLiteral("null");
    default:
        return QStringLiteral("unknown");
    }
}

int luminance(QRgb p)
{
    return (qRed(p) * 299 + qGreen(p) * 587 + qBlue(p) * 114) / 1000;
}

QString hex(QRgb p)
{
    return QStringLiteral("#%1%2%3")
            .arg(qRed(p), 2, 16, QLatin1Char('0'))
            .arg(qGreen(p), 2, 16, QLatin1Char('0'))
            .arg(qBlue(p), 2, 16, QLatin1Char('0'));
}

bool loadRoot(QQmlEngine &engine, const QString &inPath, QObject **root)
{
    QQmlComponent component(&engine, QUrl::fromLocalFile(inPath));
    if (component.isLoading()) {
        QEventLoop loop;
        QObject::connect(&component, &QQmlComponent::statusChanged, &loop, [&](QQmlComponent::Status s) {
            if (s != QQmlComponent::Loading)
                loop.quit();
        });
        QTimer::singleShot(15000, &loop, &QEventLoop::quit);
        loop.exec();
    }
    *root = component.create();
    if (!*root) {
        const auto errors = component.errors();
        for (const QQmlError &e : errors)
            fprintf(stderr, "qml-shot: qml error: %s\n", qPrintable(e.toString()));
        if (errors.isEmpty())
            fprintf(stderr, "qml-shot: QML load failed: %s\n", qPrintable(inPath));
        return false;
    }
    return true;
}

// Puts the loaded root into a window of exactly width x height.
//
// A QML Window root owns its own QQuickWindow, which this harness cannot grab:
// every capture comes from the harness window (the render-control window in RHI
// mode), so resizing the QML window alone leaves the grab looking at an empty
// window and the still comes out black. Instead the QML window is hidden,
// resized, and its direct content items are moved under the harness window's
// root item, which is the same size, so anchors and relative bindings resolve
// to the same geometry and the still shows what the window would show.
bool sizeRoot(QObject *root, QQuickWindow *window, int width, int height, bool *rootIsWindow)
{
    window->resize(width, height);
    window->setColor(QColor(0, 0, 0));
    if (auto *qmlWindow = qobject_cast<QQuickWindow *>(root)) {
        *rootIsWindow = true;
        qmlWindow->setVisible(false);
        qmlWindow->resize(width, height);
        // The Window's own colour belongs to the window, not to its content
        // item, so carry it over as the grab background.
        if (qmlWindow->color().isValid() && qmlWindow->color().alpha() > 0)
            window->setColor(qmlWindow->color());
        QQuickItem *content = qmlWindow->contentItem();
        content->setSize(QSizeF(width, height));
        // Reparent under a container with an explicit size: the grab window's
        // contentItem has no guaranteed geometry of its own until it is shown,
        // and anchored children need a correctly sized parent.
        auto *container = new QQuickItem(window->contentItem());
        container->setPosition(QPointF(0, 0));
        container->setSize(QSizeF(width, height));
        // Copy first: setParentItem() mutates the child list while we iterate.
        const QList<QQuickItem *> children = content->childItems();
        if (children.isEmpty())
            fprintf(stderr, "qml-shot: root is a Window with no content items\n");
        for (QQuickItem *child : children)
            child->setParentItem(container);
        return true;
    }
    auto *item = qobject_cast<QQuickItem *>(root);
    if (!item) {
        fprintf(stderr, "qml-shot: root is neither Item nor Window: %s\n",
                root->metaObject()->className());
        return false;
    }
    item->setParentItem(window->contentItem());
    item->setPosition(QPointF(0, 0));
    item->setSize(QSizeF(width, height));
    return true;
}

QImage grabViaWindow(QObject *root, int width, int height, QString *api, int *framesOut,
                    bool *rootIsWindow)
{
    QQuickWindow window;
    if (!sizeRoot(root, &window, width, height, rootIsWindow))
        return {};

    std::atomic<int> frames{0};
    QObject::connect(&window, &QQuickWindow::afterRendering, &window,
                     [&frames]() { frames.fetch_add(1); }, Qt::DirectConnection);

    window.show();
    window.requestUpdate();
    QEventLoop loop;
    const int settle = qEnvironmentVariableIntValue("QML_SHOT_DELAY");
    QTimer::singleShot(settle > 0 ? settle : 800, &loop, &QEventLoop::quit);
    loop.exec();

    *framesOut = frames.load();
    if (auto *ri = window.rendererInterface())
        *api = apiName(ri->graphicsApi());
    return window.grabWindow();
}

QImage grabViaRhi(QObject *root, int width, int height, QString *api, int *framesOut,
                  QString *how, bool *rootIsWindow)
{
    QQuickRenderControl control;
    // Declared before the window so the window dies first: the window borrows
    // the QVulkanInstance for the lifetime of the render control.
    QVulkanInstance vkInstance;
    // Linux offscreen: the offscreen QPA plugin cannot create an OpenGL
    // context and the software scenegraph does not draw ShaderEffect at all,
    // so the only GPU path is Vulkan through Qt RHI. Render control draws into
    // a QRhi texture, which needs no surface, so no window is ever shown.
    const QString rhiBackend = qEnvironmentVariable("QSG_RHI_BACKEND",
                                                    QStringLiteral("vulkan"));
    if (rhiBackend == QLatin1String("vulkan")) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
        // Do NOT call QVulkanInstance::create(): the offscreen QPA plugin has
        // no Vulkan factory ("This plugin does not support
        // createPlatformVulkanInstance"), and a failed create() leaves the
        // object in a state where setVkInstance() is rejected, so
        // QRhiVulkan then reports "Vulkan instance is not valid". Build the
        // instance directly and hand it over before anything else touches it.
        {
            VkApplicationInfo appInfo{};
            appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
            appInfo.pApplicationName = "hud-v5-shot";
            appInfo.apiVersion = VK_API_VERSION_1_0;
            VkInstanceCreateInfo createInfo{};
            createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
            createInfo.pApplicationInfo = &appInfo;
            VkInstance rawInstance = VK_NULL_HANDLE;
            const VkResult vr = vkCreateInstance(&createInfo, nullptr, &rawInstance);
            if (vr != VK_SUCCESS || rawInstance == VK_NULL_HANDLE) {
                fprintf(stderr, "qml-shot: vkCreateInstance failed (%d)\n", int(vr));
                return {};
            }
            vkInstance.setVkInstance(rawInstance);
            // setVkInstance takes ownership of the handle: QVulkanInstance
            // destroys it when it goes out of scope.
        }
    }
    QQuickWindow window(&control);
    if (rhiBackend == QLatin1String("vulkan"))
        window.setVulkanInstance(&vkInstance);
    if (!sizeRoot(root, &window, width, height, rootIsWindow))
        return {};

    if (!control.initialize()) {
        fprintf(stderr, "qml-shot: QQuickRenderControl::initialize() failed\n");
        return {};
    }
    QRhi *rhi = control.rhi();
    if (!rhi) {
        fprintf(stderr, "qml-shot: render control has no QRhi\n");
        return {};
    }
    *api = rhiApiName(rhi->backend());
    gGpuName = rhi->driverInfo().deviceName;
    if (gGpuName.isEmpty())
        gGpuName = QStringLiteral("unknown");

    auto *texture = rhi->newTexture(QRhiTexture::RGBA8, QSize(width, height), 1,
                                    QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource);
    auto *depth = rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, QSize(width, height), 1);
    if (!texture->create() || !depth->create()) {
        fprintf(stderr, "qml-shot: could not create the offscreen texture\n");
        return {};
    }
    QRhiTextureRenderTargetDescription rtDesc{QRhiColorAttachment(texture)};
    rtDesc.setDepthStencilBuffer(depth);
    auto *target = rhi->newTextureRenderTarget(rtDesc);
    auto *pass = target->newCompatibleRenderPassDescriptor();
    target->setRenderPassDescriptor(pass);
    if (!target->create()) {
        fprintf(stderr, "qml-shot: could not create the offscreen render target\n");
        return {};
    }
    window.setRenderTarget(QQuickRenderTarget::fromRhiRenderTarget(target));

    // Frame 1 compiles and caches the shader pipelines; the grab uses frame 3.
    int frames = 0;
    for (int i = 0; i < 3; ++i) {
        control.beginFrame();
        control.polishItems();
        control.sync();
        control.render();
        control.endFrame();
        ++frames;
    }
    *framesOut = frames;

    QImage image;

    // Readback: hand the copy to the render queue of a short offscreen frame.
    QRhiReadbackResult readback;
    {
        QRhiResourceUpdateBatch *batch = rhi->nextResourceUpdateBatch();
        batch->readBackTexture(QRhiReadbackDescription(texture), &readback);
        QRhiCommandBuffer *cb = nullptr;
        if (rhi->beginOffscreenFrame(&cb) != QRhi::FrameOpSuccess) {
            fprintf(stderr, "qml-shot: beginOffscreenFrame() failed for the readback\n");
            return {};
        }
        cb->resourceUpdate(batch);
        rhi->endOffscreenFrame();
    }
    for (int i = 0; i < 200 && readback.data.isEmpty(); ++i)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    if (readback.data.isEmpty()) {
        fprintf(stderr, "qml-shot: readback produced no data\n");
        return {};
    }
    const QSize px = readback.pixelSize.isValid() ? readback.pixelSize : QSize(width, height);
    image = QImage(reinterpret_cast<const uchar *>(readback.data.constData()), px.width(),
                   px.height(), px.width() * 4, QImage::Format_RGBA8888).copy();
    *how = QStringLiteral("readback");
    return image;
}

} // namespace

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("qml-shot-harness"));

    const QStringList args = QCoreApplication::arguments();
    if (args.size() < 3) {
        fprintf(stderr, "usage: %s <in.qml> <out.png> [width height]\n", qPrintable(args.value(0)));
        return 64;
    }

    const QString inPath = QFileInfo(args.at(1)).absoluteFilePath();
    const QString outPath = QFileInfo(args.at(2)).absoluteFilePath();
    if (!QFileInfo::exists(inPath)) {
        fprintf(stderr, "qml-shot: input does not exist: %s\n", qPrintable(inPath));
        return 64;
    }

    int width = 2560;
    int height = 1440;
    bool okW = true;
    bool okH = true;
    if (args.size() > 3)
        width = args.at(3).toInt(&okW);
    if (args.size() > 4)
        height = args.at(4).toInt(&okH);
    if (!okW || !okH || width <= 0 || height <= 0) {
        fprintf(stderr, "qml-shot: bad size '%s x %s'\n", qPrintable(args.value(3)),
                qPrintable(args.value(4)));
        return 64;
    }

    const QString mode = qEnvironmentVariable("QML_SHOT_MODE", QStringLiteral("auto"));

    // The offscreen QPA plugin cannot host an RHI swapchain, so Qt silently
    // selects the software scenegraph adaptation there and ShaderEffect items
    // are not drawn at all. The RHI adaptation plus QQuickRenderControl (render
    // into a texture, no window surface) is the working offscreen GPU path, and
    // QT_QUICK_BACKEND=rhi is what selects it. An explicit value always wins.
    if (mode != QLatin1String("window") && qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND"))
        qputenv("QT_QUICK_BACKEND", "rhi");

    QQmlEngine engine;
    QObject *root = nullptr;
    // The engine outlives both attempts; a failed RHI attempt still leaves the
    // QML object tree valid for the window fallback.
    if (!loadRoot(engine, inPath, &root))
        return 2;
    if (!qobject_cast<QQuickItem *>(root) && !qobject_cast<QQuickWindow *>(root)) {
        fprintf(stderr, "qml-shot: root is neither Item nor Window: %s\n",
                root->metaObject()->className());
        return 2;
    }

    QImage image;
    QString api = QStringLiteral("none");
    QString how;
    QString modeUsed;
    bool rootIsWindow = false;
    int frames = 0;

    if (mode != QLatin1String("window")) {
        image = grabViaRhi(root, width, height, &api, &frames, &how, &rootIsWindow);
        modeUsed = QStringLiteral("rhi");
        if (image.isNull() && mode != QLatin1String("window")) {
            fprintf(stderr, "qml-shot: RHI mode failed\n");
            return 1;
        }
        if (image.isNull())
            fprintf(stderr, "qml-shot: RHI mode failed, falling back to the software window path\n");
    }
    if (image.isNull()) {
        // The software adaptation is the only one a plain offscreen window can
        // drive; layout and text still render there, shaders do not.
        if (mode == QLatin1String("auto"))
            qputenv("QT_QUICK_BACKEND", "software");
        image = grabViaWindow(root, width, height, &api, &frames, &rootIsWindow);
        modeUsed = QStringLiteral("window");
        how = QStringLiteral("grabWindow");
        if (image.isNull()) {
            fprintf(stderr, "qml-shot: grabWindow returned a null image\n");
            return 1;
        }
    }

    if (!image.save(outPath, "PNG")) {
        fprintf(stderr, "qml-shot: could not write %s\n", qPrintable(outPath));
        return 1;
    }

    const QImage rgb = image.convertToFormat(QImage::Format_RGB32);
    QSet<QRgb> seen;
    int minLum = 255;
    int maxLum = 0;
    const qint64 pixels = qint64(rgb.width()) * rgb.height();
    const int step = int(std::max<qint64>(1, pixels / 200000));
    for (int y = 0; y < rgb.height(); y += step) {
        const auto *line = reinterpret_cast<const QRgb *>(rgb.constScanLine(y));
        for (int x = 0; x < rgb.width(); x += step) {
            const QRgb p = line[x];
            if (seen.size() < 100000)
                seen.insert(p);
            const int l = luminance(p);
            minLum = std::min(minLum, l);
            maxLum = std::max(maxLum, l);
        }
    }

    printf("qt=%s platform=%s mode=%s api=%s gpu=%s capture=%s root=%s frames=%d image=%dx%d distinct=%d "
           "minlum=%d maxlum=%d center=%s corner=%s saved=%s\n",
           qVersion(), qPrintable(QGuiApplication::platformName()),
           qPrintable(modeUsed),
           qPrintable(api), qPrintable(gGpuName), qPrintable(how),
           rootIsWindow ? "window" : "item", frames, image.width(), image.height(),
           int(seen.size()), minLum, maxLum,
           qPrintable(hex(rgb.pixel(rgb.width() / 2, rgb.height() / 2))),
           qPrintable(hex(rgb.pixel(0, 0))), qPrintable(outPath));
    fflush(stdout);
    return 0;
}
