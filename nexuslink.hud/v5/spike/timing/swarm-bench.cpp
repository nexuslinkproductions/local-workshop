// swarm-bench: render one QML effect N frames offscreen and report the frame
// time distribution. Mirrors tools/harness (QQuickRenderControl + RHI, the only
// path where ShaderEffect executes on this Mac) but loops instead of grabbing.
//
//   swarm-bench <in.qml> <width> <height> <frames> [settle_ms]
//
// Each frame advances the root's "benchPhase" property (0..1) so animation work
// cannot be optimised away, waits for the GPU, and records the elapsed time.
// Prints one line of key=value plus the raw samples on stderr:
//   mode=rhi api=metal frames=300 mean_ms=1.234 p50_ms=... p95_ms=... max_ms=...
// Exit 0 on success, 2 QML load failed, 3 GPU setup failed, 64 usage.

#include <QFileInfo>
#include <QGuiApplication>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <rhi/qrhi.h>
#include <QElapsedTimer>
#include <QUrl>
#include <QStringList>
#include <QThread>
#include <QQmlComponent>
#include <QQmlEngine>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    const QStringList args = QCoreApplication::arguments();
    if (args.size() < 5) {
        fprintf(stderr, "usage: %s <in.qml> <w> <h> <frames> [settle_ms]\n", qPrintable(args.value(0)));
        return 64;
    }
    const QString inPath = QFileInfo(args.at(1)).absoluteFilePath();
    const int width = args.at(2).toInt();
    const int height = args.at(3).toInt();
    const int frames = args.at(4).toInt();
    const int settle = args.size() > 5 ? args.at(5).toInt() : 60;
    if (!QFileInfo::exists(inPath) || width <= 0 || height <= 0 || frames <= 0)
        return 64;

    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND"))
        qputenv("QT_QUICK_BACKEND", "rhi");

    QQmlEngine engine;
    QQmlComponent component(&engine, QUrl::fromLocalFile(inPath));
    QObject *root = component.create();
    if (!root) {
        for (const QQmlError &e : component.errors())
            fprintf(stderr, "bench: qml error: %s\n", qPrintable(e.toString()));
        return 2;
    }
    QQuickRenderControl control;
    QQuickWindow window(&control);
    window.resize(width, height);
    window.setColor(QColor(0, 0, 0));
    auto *item = qobject_cast<QQuickItem *>(root);
    if (!item) {
        fprintf(stderr, "bench: root must be an Item\n");
        return 2;
    }
    item->setParentItem(window.contentItem());
    item->setPosition(QPointF(0, 0));
    item->setSize(QSizeF(width, height));

    if (!control.initialize()) {
        fprintf(stderr, "bench: initialize() failed\n");
        return 3;
    }
    QRhi *rhi = control.rhi();
    if (!rhi) {
        fprintf(stderr, "bench: no QRhi\n");
        return 3;
    }
    auto *texture = rhi->newTexture(QRhiTexture::RGBA8, QSize(width, height), 1,
                                    QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource);
    auto *depth = rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, QSize(width, height), 1);
    if (!texture->create() || !depth->create()) {
        fprintf(stderr, "bench: texture setup failed\n");
        return 3;
    }
    QRhiTextureRenderTargetDescription rtDesc{QRhiColorAttachment(texture)};
    rtDesc.setDepthStencilBuffer(depth);
    auto *target = rhi->newTextureRenderTarget(rtDesc);
    auto *pass = target->newCompatibleRenderPassDescriptor();
    target->setRenderPassDescriptor(pass);
    if (!target->create()) {
        fprintf(stderr, "bench: render target failed\n");
        return 3;
    }
    window.setRenderTarget(QQuickRenderTarget::fromRhiRenderTarget(target));

    const char *mode = "rhi";
    const char *api = "unknown";
    switch (rhi->backend()) {
    case QRhi::Metal: api = "metal"; break;
    case QRhi::OpenGLES2: api = "opengl"; break;
    case QRhi::Vulkan: api = "vulkan"; break;
    case QRhi::Null: api = "null"; break;
    default: break;
    }

    // warm up: shader pipelines, texture upload, one settle period
    for (int i = 0; i < 12; ++i) {
        root->setProperty("benchPhase", double(i) / 12.0);
        control.beginFrame();
        control.polishItems();
        control.sync();
        control.render();
        control.endFrame();
    }
    rhi->finish();
    if (settle > 0)
        QThread::msleep(settle);

    std::vector<double> samples;
    samples.reserve(frames);
    for (int i = 0; i < frames; ++i) {
        root->setProperty("benchPhase", double(i) / double(frames));
        QElapsedTimer t;
        t.start();
        control.beginFrame();
        control.polishItems();
        control.sync();
        control.render();
        control.endFrame();
        rhi->finish();                       // wait for the GPU, not just submit
        samples.push_back(double(t.nsecsElapsed()) / 1e6);
    }

    std::sort(samples.begin(), samples.end());
    double sum = 0;
    for (double s : samples) sum += s;
    const double mean = sum / samples.size();
    auto pct = [&](double p) { return samples[size_t(p * (samples.size() - 1))]; };
    double var = 0;
    for (double s : samples) var += (s - mean) * (s - mean);
    var /= samples.size();

    printf("mode=%s api=%s frames=%d size=%dx%d mean_ms=%.3f sd_ms=%.3f p50_ms=%.3f "
           "p95_ms=%.3f max_ms=%.3f\n",
           mode, api, frames, width, height, mean, std::sqrt(var), pct(0.50), pct(0.95),
           samples.back());
    if (qEnvironmentVariableIsSet("SWARM_BENCH_RAW")) {
        fprintf(stderr, "samples_ms=");
        for (size_t i = 0; i < samples.size(); ++i)
            fprintf(stderr, "%s%.3f", i ? "," : "", samples[i]);
        fprintf(stderr, "\n");
    }
    fflush(stdout);
    return 0;
}
