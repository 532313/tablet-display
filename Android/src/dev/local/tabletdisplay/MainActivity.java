package dev.local.tabletdisplay;

import android.app.Activity;
import android.content.res.Configuration;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Choreographer;
import android.view.Display;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.concurrent.ArrayBlockingQueue;

public final class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "TabletDisplay";
    private static final int PORT = 9137;
    private String serverHost;
    private int serverPort;
    private String token = "";
    private SurfaceView screen;
    private TextView status;
    private volatile boolean running;
    private Thread videoThread;
    private volatile Socket videoSocket;
    private InputSender inputSender;
    private long lastMoveNs;
    private boolean pointerDown;
    private float lastPointerX = 0.5f;
    private float lastPointerY = 0.5f;
    private float mappedX;
    private float mappedY;
    private volatile boolean videoVisible;
    private volatile int videoWidth;
    private volatile int videoHeight;
    private volatile int videoFps = 60;
    private volatile long vsyncPhaseNs;
    private volatile long vsyncIntervalNs = 16_666_667L;
    private Choreographer choreographer;
    private boolean vsyncScheduled;
    private final Choreographer.FrameCallback vsyncCallback = new Choreographer.FrameCallback() {
        @Override public void doFrame(long frameTimeNanos) {
            vsyncPhaseNs = frameTimeNanos;
            if (running && choreographer != null) choreographer.postFrameCallback(this);
        }
    };
    private long statsStartNs;
    private int statsReceived;
    private int statsOutput;
    private long statsBytes;
    private long statsInputWaitNs;
    private long statsOutputAgeUs;
    private long statsMaxOutputAgeUs;
    private int statsMaxBufferedBytes;
    private final Object statsLock = new Object();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        serverHost = getIntent().getStringExtra("host");
        if (serverHost == null || serverHost.isEmpty()) serverHost = "127.0.0.1";
        serverPort = getIntent().getIntExtra("port", PORT);
        if (serverPort < 1 || serverPort > 65535) serverPort = PORT;
        token = getIntent().getStringExtra("token");
        if (token == null) token = "";
        Display display = getWindowManager().getDefaultDisplay();
        float refreshRate = display.getRefreshRate();
        if (refreshRate > 1f && refreshRate < 240f) {
            vsyncIntervalNs = Math.max(8_000_000L, (long) (1_000_000_000f / refreshRate));
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        hideSystemUi();

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        screen = new SurfaceView(this);
        screen.getHolder().addCallback(this);
        root.addView(screen, new FrameLayout.LayoutParams(-1, -1));
        status = new TextView(this);
        status.setText("正在连接 Mac 扩展屏…");
        status.setTextColor(Color.WHITE);
        status.setTextSize(16);
        status.setBackgroundColor(0x99000000);
        status.setPadding(24, 16, 24, 16);
        FrameLayout.LayoutParams label = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.LEFT);
        label.setMargins(20, 20, 0, 0);
        root.addView(status, label);
        setContentView(root);
        screen.setOnTouchListener((view, event) -> {
            if (inputSender == null) return true;
            int action = event.getActionMasked();
            byte phase;
            if (action == MotionEvent.ACTION_DOWN) phase = 1;
            else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) phase = 3;
            else if (action == MotionEvent.ACTION_MOVE) {
                long now = System.nanoTime();
                if (now - lastMoveNs < 8_000_000L) return true;
                lastMoveNs = now;
                phase = 2;
            } else return true;
            sendPointer(view, event.getX(), event.getY(), phase);
            return true;
        });
    }

    // The video is letterboxed by MediaCodec's SCALE_TO_FIT mode when its
    // aspect ratio differs from the SurfaceView. Map touches into the area
    // that actually shows video instead of the whole screen.
    private boolean mapToVideo(View view, float x, float y) {
        int viewWidth = view.getWidth();
        int viewHeight = view.getHeight();
        if (viewWidth <= 0 || viewHeight <= 0) return false;
        int width = videoWidth;
        int height = videoHeight;
        if (width > 0 && height > 0) {
            float scale = Math.min((float) viewWidth / width, (float) viewHeight / height);
            float shownWidth = width * scale;
            float shownHeight = height * scale;
            float left = (viewWidth - shownWidth) / 2f;
            float top = (viewHeight - shownHeight) / 2f;
            x = (x - left) / shownWidth;
            y = (y - top) / shownHeight;
        } else {
            x /= viewWidth;
            y /= viewHeight;
        }
        if (x < 0f || x > 1f || y < 0f || y > 1f) return false;
        mappedX = x;
        mappedY = y;
        return true;
    }

    private void sendPointer(View view, float x, float y, byte phase) {
        if (phase == 1) {
            // Never start a gesture from a black bar. A down that was not
            // accepted must not produce a matching up later.
            if (!mapToVideo(view, x, y)) return;
            pointerDown = true;
            lastPointerX = mappedX;
            lastPointerY = mappedY;
            inputSender.send((byte) 1, lastPointerX, lastPointerY);
            return;
        }
        if (!pointerDown) return;
        if (phase == 2) {
            // Dragging inside the black bar keeps the cursor at the last
            // valid position; it must not move outside the video area.
            if (!mapToVideo(view, x, y)) return;
            lastPointerX = mappedX;
            lastPointerY = mappedY;
            inputSender.send((byte) 2, lastPointerX, lastPointerY);
            return;
        }
        // ACTION_UP / ACTION_CANCEL: always send up, even if the finger left
        // the video rectangle. Otherwise the Mac can stay in mouse-down state.
        pointerDown = false;
        inputSender.send((byte) 3, lastPointerX, lastPointerY);
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN |
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }

    @Override public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        hideSystemUi();
    }

    @Override public void surfaceCreated(SurfaceHolder holder) {
        running = true;
        pointerDown = false;
        if (choreographer == null) choreographer = Choreographer.getInstance();
        if (!vsyncScheduled) {
            choreographer.postFrameCallback(vsyncCallback);
            vsyncScheduled = true;
        }
        applySurfaceFrameRate(holder);
        inputSender = new InputSender();
        inputSender.start();
        videoThread = new Thread(() -> receiveVideo(holder), "tablet-display-video");
        videoThread.start();
    }

    private void applySurfaceFrameRate(SurfaceHolder holder) {
        if (Build.VERSION.SDK_INT < 30) return;
        try {
            holder.getSurface().setFrameRate(videoFps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
        } catch (Exception ignored) {
            // Some vendor compositors reject frame-rate hints; pacing still works.
        }
    }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        applySurfaceFrameRate(holder);
    }

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        running = false;
        if (pointerDown && inputSender != null) {
            pointerDown = false;
            inputSender.send((byte) 3, lastPointerX, lastPointerY);
        }
        if (choreographer != null && vsyncScheduled) {
            choreographer.removeFrameCallback(vsyncCallback);
            vsyncScheduled = false;
        }
        if (inputSender != null) inputSender.shutdown();
        Socket socket = videoSocket;
        if (socket != null) try { socket.close(); } catch (IOException ignored) {}
        if (videoThread != null) videoThread.interrupt();
    }

    private void showStatus(String message) {
        runOnUiThread(() -> { status.setText(message); status.setVisibility(View.VISIBLE); });
    }

    private void receiveVideo(SurfaceHolder holder) {
        int reconnectAttempts = 0;
        while (running) {
            MediaCodec codec = null;
            DecoderOutput output = null;
            try (Socket socket = new Socket()) {
                videoSocket = socket;
                socket.setTcpNoDelay(true);
                socket.setKeepAlive(true);
                socket.setReceiveBufferSize(256 * 1024);
                socket.setSoTimeout(5000);
                socket.connect(new InetSocketAddress(serverHost, serverPort), 3000);
                DataOutputStream request = new DataOutputStream(socket.getOutputStream());
                StringBuilder requestHead = new StringBuilder("GET /video HTTP/1.1\r\nHost: localhost\r\n");
                if (!token.isEmpty()) requestHead.append("Authorization: Bearer ").append(token).append("\r\n");
                requestHead.append("\r\n");
                request.writeBytes(requestHead.toString());
                request.flush();
                DataInputStream input = new DataInputStream(new BufferedInputStream(socket.getInputStream(), 128 * 1024));
                VideoProtocol.readHttpHeader(input);
                int width = input.readInt();
                int height = input.readInt();
                int fps = input.readInt();
                VideoProtocol.validateVideoSize(width, height);
                if (fps < 1 || fps > 120) fps = 60;
                videoWidth = width;
                videoHeight = height;
                videoFps = fps;
                runOnUiThread(() -> { if (screen != null) applySurfaceFrameRate(screen.getHolder()); });
                Log.i(TAG, "Video " + width + "x" + height + " @" + fps + "fps");
                resetStats();
                reconnectAttempts = 0;
                while (running) {
                    VideoProtocol.Frame frame = VideoProtocol.readFrame(input);
                    synchronized (statsLock) {
                        statsReceived++;
                        statsBytes += frame.data.length;
                        statsMaxBufferedBytes = Math.max(statsMaxBufferedBytes, input.available());
                    }
                    if (codec == null) {
                        if (!frame.keyframe) continue;
                        codec = configureDecoder(width, height, fps, frame.data, holder);
                        output = new DecoderOutput(codec, socket);
                        output.start();
                    }
                    queueFrame(codec, output, frame.data);
                    reportStatsIfDue();
                }
            } catch (Exception error) {
                Log.e(TAG, "Video connection", error);
                videoVisible = false;
                if (ReconnectPolicy.shouldRetry(running)) {
                    showStatus("连接中断，正在重试…");
                    long delay = ReconnectPolicy.delayMillis(reconnectAttempts++);
                    try { Thread.sleep(delay); } catch (InterruptedException ignored) {}
                }
            } finally {
                videoSocket = null;
                if (output != null) {
                    output.shutdown();
                    try { output.join(); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
                }
                if (codec != null) {
                    try { codec.stop(); } catch (Exception ignored) {}
                    codec.release();
                }
            }
        }
    }

    private static MediaCodec configureDecoder(int width, int height, int fps, byte[] firstFrame, SurfaceHolder holder) throws IOException {
        ArrayList<byte[]> nals = VideoProtocol.splitNals(firstFrame);
        byte[] sps = null, pps = null;
        for (byte[] nal : nals) {
            if (nal.length < 5) continue;
            int type = nal[4] & 0x1f;
            if (type == 7) sps = nal;
            if (type == 8) pps = nal;
        }
        if (sps == null || pps == null) throw new IOException("Keyframe lacks SPS/PPS");
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setByteBuffer("csd-0", ByteBuffer.wrap(sps));
        format.setByteBuffer("csd-1", ByteBuffer.wrap(pps));
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setFloat(MediaFormat.KEY_OPERATING_RATE, Math.max(15f, Math.min(120f, fps)));
        MediaCodec codec = createHardwareDecoder();
        try {
            if (android.os.Build.VERSION.SDK_INT >= 30 &&
                codec.getCodecInfo().getCapabilitiesForType("video/avc").isFeatureSupported(
                    MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
            }
            Log.i(TAG, "Decoder " + codec.getName());
            codec.configure(format, holder.getSurface(), null, 0);
            codec.start();
            codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT);
            return codec;
        } catch (Exception error) {
            codec.release();
            throw new IOException("Decoder setup failed", error);
        }
    }

    private static MediaCodec createHardwareDecoder() throws IOException {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder() || !info.isHardwareAccelerated()) continue;
            for (String type : info.getSupportedTypes()) {
                if ("video/avc".equalsIgnoreCase(type)) return MediaCodec.createByCodecName(info.getName());
            }
        }
        return MediaCodec.createDecoderByType("video/avc");
    }

    private void queueFrame(MediaCodec codec, DecoderOutput output, byte[] frame) throws IOException {
        int index = -1;
        long waitStartNs = System.nanoTime();
        while (running && index < 0) {
            if (!output.isAlive()) throw new IOException("Decoder output stopped");
            index = codec.dequeueInputBuffer(10_000);
        }
        synchronized (statsLock) { statsInputWaitNs += System.nanoTime() - waitStartNs; }
        if (!running) return;
        ByteBuffer buffer = codec.getInputBuffer(index);
        if (buffer == null || buffer.capacity() < frame.length) throw new IOException("Decoder input too small");
        buffer.clear();
        buffer.put(frame);
        codec.queueInputBuffer(index, 0, frame.length, System.nanoTime() / 1_000L, 0);
    }

    private final class DecoderOutput extends Thread {
        private final MediaCodec codec;
        private final Socket socket;
        private volatile boolean active = true;
        private long nextPresentNs;

        DecoderOutput(MediaCodec codec, Socket socket) {
            super("tablet-display-decoder-output");
            this.codec = codec;
            this.socket = socket;
        }

        void shutdown() { active = false; interrupt(); }

        @Override public void run() {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            try {
                while (running && active) {
                    int index = codec.dequeueOutputBuffer(info, 10_000);
                    if (index >= 0) {
                        long ageUs = Math.max(0, System.nanoTime() / 1_000L - info.presentationTimeUs);
                        synchronized (statsLock) {
                            statsOutput++;
                            statsOutputAgeUs += ageUs;
                            statsMaxOutputAgeUs = Math.max(statsMaxOutputAgeUs, ageUs);
                        }
                        // Schedule presentation on the display's vsync grid instead of
                        // releasing bursts immediately. Two buffers released inside one
                        // vsync interval make SurfaceFlinger drop one, which showed up as
                        // ~53 fps presentation with a 60 fps decoder.
                        long now = System.nanoTime();
                        long interval = Math.max(8_000_000L, vsyncIntervalNs);
                        long target = Math.max(nextPresentNs, now);
                        long phase = vsyncPhaseNs;
                        if (phase > 0 && now >= phase) {
                            long nextVsync = phase + ((now - phase) / interval + 1) * interval;
                            if (target < nextVsync) target = nextVsync;
                        }
                        if (target - now > 3 * interval) target = now + interval;
                        codec.releaseOutputBuffer(index, target);
                        nextPresentNs = target + interval;
                        if (!videoVisible) {
                            videoVisible = true;
                            runOnUiThread(() -> status.setVisibility(View.GONE));
                        }
                    } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        Log.i(TAG, "Output " + codec.getOutputFormat());
                    }
                }
            } catch (Exception error) {
                if (active && running) {
                    Log.e(TAG, "Decoder output", error);
                    try { socket.close(); } catch (IOException ignored) {}
                }
            }
        }
    }

    private void resetStats() {
        synchronized (statsLock) {
            statsStartNs = System.nanoTime();
            statsReceived = statsOutput = statsMaxBufferedBytes = 0;
            statsBytes = statsInputWaitNs = statsOutputAgeUs = statsMaxOutputAgeUs = 0;
        }
    }

    private void reportStatsIfDue() {
        synchronized (statsLock) {
            long now = System.nanoTime();
            double seconds = (now - statsStartNs) / 1_000_000_000.0;
            if (seconds < 5) return;
            Log.w(TAG, String.format(java.util.Locale.US,
                "video stats recv=%.1ffps output=%.1ffps Mbps=%.1f inputWait=%.1fms/frame outputAge=%.1fms maxAge=%.1fms maxBuffered=%dKB",
                statsReceived / seconds, statsOutput / seconds, statsBytes * 8 / seconds / 1_000_000,
                statsInputWaitNs / 1_000_000.0 / Math.max(1, statsReceived),
                statsOutputAgeUs / 1_000.0 / Math.max(1, statsOutput), statsMaxOutputAgeUs / 1_000.0,
                statsMaxBufferedBytes / 1024));
            statsStartNs = now;
            statsReceived = statsOutput = statsMaxBufferedBytes = 0;
            statsBytes = statsInputWaitNs = statsOutputAgeUs = statsMaxOutputAgeUs = 0;
        }
    }

    private static final class Pointer {
        final byte phase;
        final float x, y;
        Pointer(byte phase, float x, float y) { this.phase = phase; this.x = x; this.y = y; }
    }

    private final class InputSender extends Thread {
        private final ArrayBlockingQueue<Pointer> queue = new ArrayBlockingQueue<>(64);
        private volatile boolean active = true;
        InputSender() { super("tablet-display-input"); }
        void send(byte phase, float x, float y) {
            if (!queue.offer(new Pointer(phase, x, y))) {
                queue.poll();
                queue.offer(new Pointer(phase, x, y));
            }
        }
        void shutdown() { active = false; interrupt(); }
        @Override public void run() {
            while (active) {
                try (Socket socket = new Socket()) {
                    socket.setTcpNoDelay(true);
                    socket.setKeepAlive(true);
                    socket.connect(new InetSocketAddress(serverHost, serverPort), 3000);
                    DataOutputStream output = new DataOutputStream(socket.getOutputStream());
                    StringBuilder requestHead = new StringBuilder("GET /input HTTP/1.1\r\nHost: localhost\r\n");
                    if (!token.isEmpty()) requestHead.append("Authorization: Bearer ").append(token).append("\r\n");
                    requestHead.append("\r\n");
                    output.writeBytes(requestHead.toString());
                    output.flush();
                    VideoProtocol.readHttpHeader(socket.getInputStream());
                    while (active) {
                        Pointer pointer = queue.take();
                        output.writeByte(pointer.phase);
                        output.writeFloat(pointer.x);
                        output.writeFloat(pointer.y);
                        output.flush();
                    }
                } catch (Exception error) {
                    if (active) {
                        Log.w(TAG, "Input connection", error);
                        try { Thread.sleep(500); } catch (InterruptedException ignored) {}
                    }
                }
            }
        }
    }
}
