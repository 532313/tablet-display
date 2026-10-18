package dev.local.tabletdisplay;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;

/**
 * Minimal RTP/H.264 receiver. The Mac sender packetizes one access unit per RTP
 * timestamp; a sequence gap asks for a fresh IDR and drops the damaged frame.
 */
final class RtpVideoReceiver implements Closeable {
    interface Listener {
        void onMetadata(int width, int height, int fps);
        void onFrame(byte[] annexB, boolean keyframe);
    }

    private static final long HELLO_INTERVAL_NS = 200_000_000L;
    private static final long KEYFRAME_INTERVAL_NS = 250_000_000L;
    private static final long PING_INTERVAL_NS = 1_000_000_000L;
    private static final long START_TIMEOUT_NS = 2_000_000_000L;
    private static final long STALL_TIMEOUT_NS = 2_000_000_000L;

    private final InetAddress server;
    private final int port;
    private final String token;
    private final Listener listener;
    private final DatagramSocket socket;

    private volatile boolean running = true;
    private boolean metadata;
    private int width = 1920;
    private int height = 1200;
    private int fps = 60;

    private int expectedSequence = -1;
    private long frameTimestamp = -1;
    private final ByteArrayOutputStream frame = new ByteArrayOutputStream(256 * 1024);
    private final ByteArrayOutputStream nal = new ByteArrayOutputStream(64 * 1024);
    private boolean frameKeyframe;
    private boolean fuActive;
    private boolean waitingKeyframe = true;
    private long lastKeyframeRequestNs;
    private long lastPingNs;
    private long firstRtpNs;
    private long lastRtpNs;

    RtpVideoReceiver(String host, int port, String token, Listener listener) throws IOException {
        this.server = InetAddress.getByName(host);
        this.port = port;
        this.token = token;
        this.listener = listener;
        socket = new DatagramSocket();
        socket.setReceiveBufferSize(1 << 20);
        socket.setSoTimeout(200);
    }

    DatagramSocket socket() {
        return socket;
    }

    void run() throws IOException {
        byte[] buffer = new byte[2048];
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        byte[] hello = ("HELLO " + token + "\n").getBytes(StandardCharsets.UTF_8);
        byte[] keyframeRequest = "KEYFRAME\n".getBytes(StandardCharsets.UTF_8);
        long start = System.nanoTime();
        long lastHello = 0;

        while (running) {
            long now = System.nanoTime();
            if (!metadata && now - lastHello >= HELLO_INTERVAL_NS) {
                send(hello);
                lastHello = now;
            }
            if (!metadata && now - start >= START_TIMEOUT_NS) {
                throw new IOException("UDP 元数据超时");
            }
            if (metadata && firstRtpNs == 0 && now - start >= START_TIMEOUT_NS) {
                throw new IOException("UDP 视频超时");
            }
            if (firstRtpNs != 0 && now - lastRtpNs >= STALL_TIMEOUT_NS) {
                throw new IOException("UDP 视频中断");
            }
            if (waitingKeyframe && now - lastKeyframeRequestNs >= KEYFRAME_INTERVAL_NS) {
                send(keyframeRequest);
                lastKeyframeRequestNs = now;
            }
            if (metadata && now - lastPingNs >= PING_INTERVAL_NS) {
                send("PING\n".getBytes(StandardCharsets.UTF_8));
                lastPingNs = now;
            }

            packet.setLength(buffer.length);
            try {
                socket.receive(packet);
            } catch (SocketTimeoutException timeout) {
                continue;
            }
            if (!running) break;
            int length = packet.getLength();
            if (length < 1) continue;
            if ((buffer[0] & 0x80) != 0) {
                if (firstRtpNs == 0) firstRtpNs = System.nanoTime();
                lastRtpNs = System.nanoTime();
                if (metadata) handleRtp(buffer, length);
            } else {
                handleControl(new String(buffer, 0, length, StandardCharsets.UTF_8));
            }
        }
    }

    private void handleControl(String text) {
        String message = text.trim();
        if (!message.startsWith("META ")) return;
        String[] fields = message.split("\\s+");
        if (fields.length < 4) return;
        try {
            int newWidth = Integer.parseInt(fields[1]);
            int newHeight = Integer.parseInt(fields[2]);
            int newFps = Integer.parseInt(fields[3]);
            if (newWidth < 640 || newWidth > 4096 || newHeight < 480 || newHeight > 4096) return;
            if (newFps < 1 || newFps > 120) newFps = 60;
            width = newWidth;
            height = newHeight;
            fps = newFps;
            metadata = true;
            listener.onMetadata(width, height, fps);
        } catch (NumberFormatException ignored) {
            // Ignore malformed control packets.
        }
    }

    private void handleRtp(byte[] data, int length) throws IOException {
        if (length < 12 || (data[0] & 0xC0) != 0x80) return;
        boolean marker = (data[1] & 0x80) != 0;
        int sequence = ((data[2] & 0xFF) << 8) | (data[3] & 0xFF);
        long timestamp = ((long) (data[4] & 0xFF) << 24)
                | ((long) (data[5] & 0xFF) << 16)
                | ((long) (data[6] & 0xFF) << 8)
                | (data[7] & 0xFF);

        if (expectedSequence < 0) {
            expectedSequence = sequence;
        } else if (sequence != expectedSequence) {
            int delta = (sequence - expectedSequence) & 0xFFFF;
            if (delta > 0x8000) return; // Late duplicate; no retransmission path yet.
            waitingKeyframe = true;
            requestKeyframe();
            resetFrame();
            expectedSequence = -1;
            return;
        }
        expectedSequence = (sequence + 1) & 0xFFFF;

        if (frameTimestamp != timestamp) {
            if (frame.size() > 0) {
                resetFrame();
                waitingKeyframe = true;
                requestKeyframe();
            }
            frameTimestamp = timestamp;
            frameKeyframe = false;
            fuActive = false;
        }

        int offset = 12 + (data[0] & 0x0F) * 4;
        if ((data[0] & 0x10) != 0) {
            if (offset + 4 > length) return;
            int extensionWords = ((data[offset + 2] & 0xFF) << 8) | (data[offset + 3] & 0xFF);
            offset += 4 + extensionWords * 4;
        }
        if (offset >= length) return;

        int type = data[offset] & 0x1F;
        if (type >= 1 && type <= 23) {
            appendNal(data, offset, length - offset);
        } else if (type == 24) {
            int cursor = offset + 1;
            while (cursor + 2 <= length) {
                int size = ((data[cursor] & 0xFF) << 8) | (data[cursor + 1] & 0xFF);
                cursor += 2;
                if (size <= 0 || cursor + size > length) break;
                appendNal(data, cursor, size);
                cursor += size;
            }
        } else if (type == 28) {
            if (offset + 2 > length) return;
            int indicator = data[offset] & 0xFF;
            int fuHeader = data[offset + 1] & 0xFF;
            int nalType = fuHeader & 0x1F;
            if ((fuHeader & 0x80) != 0) {
                nal.reset();
                nal.write((indicator & 0xE0) | nalType);
                fuActive = true;
            }
            if (!fuActive) return;
            nal.write(data, offset + 2, length - offset - 2);
            if ((fuHeader & 0x40) != 0) {
                byte[] completed = nal.toByteArray();
                appendNal(completed, 0, completed.length);
                nal.reset();
                fuActive = false;
            }
        }

        if (marker) {
            if (frame.size() == 0) {
                frameTimestamp = -1;
                return;
            }
            boolean key = frameKeyframe;
            if (waitingKeyframe && !key) {
                resetFrame();
                return;
            }
            if (key) waitingKeyframe = false;
            listener.onFrame(frame.toByteArray(), key);
            resetFrame();
        }
    }

    private void appendNal(byte[] data, int offset, int length) {
        if (length <= 0) return;
        int type = data[offset] & 0x1F;
        if (type == 5 || type == 7) frameKeyframe = true;
        frame.write(0);
        frame.write(0);
        frame.write(0);
        frame.write(1);
        frame.write(data, offset, length);
    }

    private void resetFrame() {
        frame.reset();
        nal.reset();
        frameKeyframe = false;
        fuActive = false;
        frameTimestamp = -1;
    }

    private void requestKeyframe() {
        long now = System.nanoTime();
        if (now - lastKeyframeRequestNs < KEYFRAME_INTERVAL_NS) return;
        send("KEYFRAME\n".getBytes(StandardCharsets.UTF_8));
        lastKeyframeRequestNs = now;
    }

    private void send(byte[] data) {
        try {
            socket.send(new DatagramPacket(data, data.length, server, port));
        } catch (IOException ignored) {
            // A failed HELLO simply means the TCP fallback will be used.
        }
    }

    @Override public void close() {
        running = false;
        socket.close();
    }
}
