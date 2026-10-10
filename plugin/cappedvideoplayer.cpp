/*
    SPDX-FileCopyrightText: 2026 Chris Modjeska <chris@implicate.dev>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "cappedvideoplayer.h"

#include <QAbstractVideoBuffer>
#include <QDebug>
#include <QVideoFrame>
#include <QVideoFrameFormat>
#include <QVideoSink>

#include <gst/video/video-frame.h>

namespace {

// Map a GStreamer video format to a Qt pixel format (Format_Invalid if unknown).
QVideoFrameFormat::PixelFormat toQtPixelFormat(GstVideoFormat fmt)
{
    switch (fmt) {
    case GST_VIDEO_FORMAT_RGBA: return QVideoFrameFormat::Format_RGBA8888;
    case GST_VIDEO_FORMAT_RGBx: return QVideoFrameFormat::Format_RGBX8888;
    case GST_VIDEO_FORMAT_BGRA: return QVideoFrameFormat::Format_BGRA8888;
    case GST_VIDEO_FORMAT_BGRx: return QVideoFrameFormat::Format_BGRX8888;
    case GST_VIDEO_FORMAT_ARGB: return QVideoFrameFormat::Format_ARGB8888;
    case GST_VIDEO_FORMAT_xRGB: return QVideoFrameFormat::Format_XRGB8888;
    case GST_VIDEO_FORMAT_ABGR: return QVideoFrameFormat::Format_ABGR8888;
    case GST_VIDEO_FORMAT_xBGR: return QVideoFrameFormat::Format_XBGR8888;
    case GST_VIDEO_FORMAT_YUY2: return QVideoFrameFormat::Format_YUYV;
    case GST_VIDEO_FORMAT_UYVY: return QVideoFrameFormat::Format_UYVY;
    case GST_VIDEO_FORMAT_NV12: return QVideoFrameFormat::Format_NV12;
    case GST_VIDEO_FORMAT_NV21: return QVideoFrameFormat::Format_NV21;
    case GST_VIDEO_FORMAT_I420: return QVideoFrameFormat::Format_YUV420P;
    case GST_VIDEO_FORMAT_YV12: return QVideoFrameFormat::Format_YV12;
    default: return QVideoFrameFormat::Format_Invalid;
    }
}

} // namespace

CappedVideoPlayer::CappedVideoPlayer(QObject *parent)
    : QObject(parent)
{
}

CappedVideoPlayer::~CappedVideoPlayer()
{
    teardownPipeline();
}

void CappedVideoPlayer::setSource(const QUrl &source)
{
    if (m_source == source) {
        return;
    }
    m_source = source;
    emit sourceChanged();
    buildPipeline();
}

void CappedVideoPlayer::setVideoSink(QVideoSink *sink)
{
    if (m_videoSink == sink) {
        return;
    }
    m_videoSink = sink;
    emit videoSinkChanged();
}

void CappedVideoPlayer::setMaxWidth(int w)
{
    if (m_maxWidth == w) {
        return;
    }
    m_maxWidth = w;
    emit maxWidthChanged();
    if (!m_source.isEmpty()) {
        buildPipeline();
    }
}

void CappedVideoPlayer::setMaxHeight(int h)
{
    if (m_maxHeight == h) {
        return;
    }
    m_maxHeight = h;
    emit maxHeightChanged();
    if (!m_source.isEmpty()) {
        buildPipeline();
    }
}

void CappedVideoPlayer::setLoops(bool loops)
{
    if (m_loops == loops) {
        return;
    }
    m_loops = loops;
    emit loopsChanged();
}

void CappedVideoPlayer::play()
{
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
        m_playing = true;
        emit playingChanged();
        if (m_mediaStatus != 4) { // QMediaPlayer::BufferedMedia
            m_mediaStatus = 4;
            emit mediaStatusChanged();
        }
    }
}

void CappedVideoPlayer::pause()
{
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_PAUSED);
        m_playing = false;
        emit playingChanged();
    }
}

void CappedVideoPlayer::stop()
{
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
        m_playing = false;
        emit playingChanged();
    }
}

void CappedVideoPlayer::seek(qint64 pos)
{
    if (!m_pipeline || !m_seekable) {
        return;
    }
    if (!gst_element_seek_simple(m_pipeline, GST_FORMAT_TIME,
                                 static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
                                 static_cast<gint64>(pos) * GST_MSECOND)) {
        qWarning() << "CappedVideoPlayer: seek failed";
    }
}

void CappedVideoPlayer::updatePosition(qint64 pos)
{
    if (m_position == pos) {
        return;
    }
    m_position = pos;
    emit positionChanged();
}

// appsink "new-sample": pull the (already-capped) buffer -> QVideoFrame -> sink.
static GstFlowReturn newSampleHandler(GstAppSink *appsink, gpointer data)
{
    auto *self = static_cast<CappedVideoPlayer *>(data);
    GstSample *sample = gst_app_sink_pull_sample(appsink);
    if (!sample) {
        return GST_FLOW_ERROR;
    }
    QMetaObject::invokeMethod(self, [self, sample]() {
        GstBuffer *buf = gst_sample_get_buffer(sample);
        GstCaps *caps = gst_sample_get_caps(sample);
        GstVideoInfo info;
        if (!buf || !caps || !gst_video_info_from_caps(&info, caps)) {
            qWarning() << "CappedVideoPlayer: no video info for frame";
            gst_sample_unref(sample);
            return;
        }

        GstMapInfo map;
        if (!gst_buffer_map(buf, &map, GST_MAP_READ)) {
            gst_sample_unref(sample);
            return;
        }

        const auto pf = toQtPixelFormat(info.finfo->format);
        if (pf == QVideoFrameFormat::Format_Invalid) {
            qWarning() << "CappedVideoPlayer: unsupported format"
                       << gst_video_format_to_string(info.finfo->format);
            gst_buffer_unmap(buf, &map);
            gst_sample_unref(sample);
            return;
        }

        QVideoFrameFormat format(QSize(info.width, info.height), pf);
        QVideoFrame frame(format);

        if (frame.map(QVideoFrame::WriteOnly)) {
            const int srcStride = info.stride[0];
            const int dstStride = frame.bytesPerLine(0);
            const int copyBytes = qMin(srcStride, dstStride);
            const int rows = info.height;
            uchar *dst = frame.bits(0);
            const uchar *src = map.data;
            for (int y = 0; y < rows; ++y) {
                memcpy(dst, src, copyBytes);
                dst += dstStride;
                src += srcStride;
            }
            frame.unmap();
        }

        gst_buffer_unmap(buf, &map);

        if (GST_BUFFER_PTS_IS_VALID(buf)) {
            self->updatePosition(static_cast<qint64>(GST_BUFFER_PTS(buf) / GST_MSECOND));
        }

        if (self->videoSink()) {
            self->videoSink()->setVideoFrame(frame);
        }
        gst_sample_unref(sample);
    }, Qt::QueuedConnection);
    return GST_FLOW_OK;
}

void CappedVideoPlayer::buildPipeline()
{
    teardownPipeline();

    if (m_source.isEmpty() || !m_source.isValid()) {
        return;
    }

    m_pipeline = gst_pipeline_new("capped-player");
    m_playbin = gst_element_factory_make("playbin", "player");
    m_appsink = gst_element_factory_make("appsink", "sink");

    GstElement *convert = gst_element_factory_make("videoconvert", "convert");
    GstElement *scale = gst_element_factory_make("videoscale", "scale");
    GstElement *filter = gst_element_factory_make("capsfilter", "cap");
    if (!m_playbin || !m_appsink || !convert || !scale || !filter) {
        qWarning() << "CappedVideoPlayer: could not create pipeline elements";
        teardownPipeline();
        return;
    }

    GstCaps *caps = gst_caps_new_simple("video/x-raw",
                                        "width", G_TYPE_INT, m_maxWidth,
                                        "height", G_TYPE_INT, m_maxHeight,
                                        nullptr);
    g_object_set(G_OBJECT(filter), "caps", caps, nullptr);
    gst_caps_unref(caps);

    GstElement *bin = gst_bin_new("sink-bin");
    gst_bin_add_many(GST_BIN(bin), convert, scale, filter, m_appsink, nullptr);
    gst_element_link_many(convert, scale, filter, m_appsink, nullptr);

    GstPad *sinkpad = gst_element_get_static_pad(convert, "sink");
    GstPad *ghost = gst_ghost_pad_new("sink", sinkpad);
    gst_element_add_pad(bin, ghost);
    gst_object_unref(sinkpad);

    g_object_set(G_OBJECT(m_appsink), "emit-signals", TRUE, nullptr);
    g_signal_connect(m_appsink, "new-sample", G_CALLBACK(newSampleHandler), this);

    g_object_set(G_OBJECT(m_playbin), "video-sink", bin, nullptr);
    g_object_set(G_OBJECT(m_playbin), "uri", QUrl(m_source).toEncoded().constData(), nullptr);
    g_object_set(G_OBJECT(m_playbin), "mute", TRUE, nullptr);

    gst_bin_add(GST_BIN(m_pipeline), m_playbin);

    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
    m_busWatchId = gst_bus_add_watch(bus, [](GstBus *, GstMessage *msg, gpointer data) -> gboolean {
        auto *self = static_cast<CappedVideoPlayer *>(data);
        switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_EOS:
            QMetaObject::invokeMethod(self, [self]() {
                if (self->loops()) {
                    self->seek(0);
                    self->play();
                } else {
                    self->stop();
                }
            }, Qt::QueuedConnection);
            break;
        case GST_MESSAGE_ERROR: {
            GError *err = nullptr;
            gchar *dbg = nullptr;
            gst_message_parse_error(msg, &err, &dbg);
            qWarning() << "CappedVideoPlayer error:" << (err ? err->message : "unknown");
            g_clear_error(&err);
            g_free(dbg);
            QMetaObject::invokeMethod(self, [self]() { self->stop(); }, Qt::QueuedConnection);
            break;
        }
        default:
            break;
        }
        return TRUE;
    }, this);
    gst_object_unref(bus);

    m_mediaStatus = 3; // LoadedMedia
    emit mediaStatusChanged();

    gst_element_set_state(m_pipeline, GST_STATE_PAUSED);
    QMetaObject::invokeMethod(this, [this]() {
        gint64 dur = 0;
        if (gst_element_query_duration(m_pipeline, GST_FORMAT_TIME, &dur)) {
            m_duration = dur / GST_MSECOND;
            emit durationChanged();
        }
        m_seekable = true;
        emit seekableChanged();
    }, Qt::QueuedConnection);
}

void CappedVideoPlayer::teardownPipeline()
{
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
        if (m_busWatchId) {
            GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
            gst_bus_remove_watch(bus);
            gst_object_unref(bus);
            m_busWatchId = 0;
        }
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
        m_playbin = nullptr;
        m_appsink = nullptr;
    }
    m_duration = 0;
    m_position = 0;
    m_seekable = false;
    m_mediaStatus = 0; // NoMedia
    emit mediaStatusChanged();
    emit durationChanged();
}

#include "moc_cappedvideoplayer.cpp"

