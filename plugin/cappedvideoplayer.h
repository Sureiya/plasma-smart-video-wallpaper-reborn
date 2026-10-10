/*
    SPDX-FileCopyrightText: 2026 Chris Modjeska <chris@implicate.dev>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#ifndef CAPPEDVIDEOPLAYER_H
#define CAPPEDVIDEOPLAYER_H

#pragma once

#include <QAbstractVideoBuffer>
#include <QObject>
#include <QQmlEngine>
#include <QUrl>
#include <QVariant>

#include <gst/gst.h>
#include <gst/app/gstappsink.h>

class QVideoSink;

/*
 * CappedVideoPlayer — a minimal GStreamer-backed video source that decodes at a
 * CAPPED resolution and hands frames to QtMultimedia's QVideoSink, so QML's
 * `VideoOutput { videoSink: player.videoSink }` can display them.
 *
 * Why this exists: QtMultimedia's QMediaPlayer+GStreamer backend decodes every
 * video at its native (source) resolution and only scales down to the output
 * surface afterwards. For Tiles mode that means N tiles each decode a full 4K
 * frame into a full-res GPU texture — the source of the multi-GB VRAM blow-up.
 * Here we insert `videoscale ! capsfilter[video/x-raw,width<=W,height<=H]`
 * AFTER decode, so the frames we upload to the GPU are already at (or below)
 * the cap. Tiles never need more than ~1080p worth of pixels.
 *
 * This is intentionally a SMALL surface — just enough to be a drop-in for the
 * subset of QtMultimedia's MediaPlayer API that VideoPlayer.qml uses in tiles
 * mode (loops, muted, seek, position/duration). Audio + full crossfade are out
 * of scope: tiles are muted and loop infinitely.
 */
class CappedVideoPlayer : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QVideoSink *videoSink READ videoSink WRITE setVideoSink NOTIFY videoSinkChanged)
    Q_PROPERTY(int maxWidth READ maxWidth WRITE setMaxWidth NOTIFY maxWidthChanged)
    Q_PROPERTY(int maxHeight READ maxHeight WRITE setMaxHeight NOTIFY maxHeightChanged)
    Q_PROPERTY(bool loops READ loops WRITE setLoops NOTIFY loopsChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool seekable READ seekable NOTIFY seekableChanged)
    Q_PROPERTY(int mediaStatus READ mediaStatus NOTIFY mediaStatusChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)

public:
    explicit CappedVideoPlayer(QObject *parent = nullptr);
    ~CappedVideoPlayer() override;

    QUrl source() const { return m_source; }
    void setSource(const QUrl &source);

    QVideoSink *videoSink() const { return m_videoSink; }
    void setVideoSink(QVideoSink *sink);

    int maxWidth() const { return m_maxWidth; }
    void setMaxWidth(int w);

    int maxHeight() const { return m_maxHeight; }
    void setMaxHeight(int h);

    bool loops() const { return m_loops; }
    void setLoops(bool loops);

    qint64 position() const { return m_position; }
    qint64 duration() const { return m_duration; }
    bool seekable() const { return m_seekable; }
    int mediaStatus() const { return m_mediaStatus; }
    bool playing() const { return m_playing; }

    // Used internally (and by the appsink callback) to advance the position.
    void updatePosition(qint64 pos);

    // Called from the caps probe once the source dimensions are known; computes
    // an aspect-preserving target <= (maxWidth,maxHeight) and sets the capsfilter.
    void applyAspectCap(int srcW, int srcH);

public slots:
    void play();
    void pause();
    void stop();
    void seek(qint64 pos);

signals:
    void sourceChanged();
    void videoSinkChanged();
    void maxWidthChanged();
    void maxHeightChanged();
    void loopsChanged();
    void positionChanged();
    void durationChanged();
    void seekableChanged();
    void mediaStatusChanged();
    void playingChanged();

private:
    void buildPipeline();
    void teardownPipeline();

    QUrl m_source;
    QVideoSink *m_videoSink = nullptr;
    int m_maxWidth = 1920;
    int m_maxHeight = 1080;
    bool m_loops = true;
    qint64 m_duration = 0;
    qint64 m_position = 0;
    bool m_seekable = false;
    int m_mediaStatus = 0; // QMediaPlayer::NoMedia
    bool m_playing = false;

    GstElement *m_pipeline = nullptr;
    GstElement *m_playbin = nullptr;
    GstElement *m_appsink = nullptr;
    GstElement *m_capsfilter = nullptr;
    GstBus *m_bus = nullptr;
};

#endif // CAPPEDVIDEOPLAYER_H
