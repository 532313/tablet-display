package dev.local.tabletdisplay;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;

import java.io.Closeable;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;

/** Receives 48kHz/stereo s16le PCM over UDP and plays it on the tablet. */
final class AudioReceiver extends Thread implements Closeable {
    private static final String TAG = "TabletDisplayAudio";
    private static final long HELLO_INTERVAL_NS = 200_000_000L;
    private static final long PING_INTERVAL_NS = 1_000_000_000L;
    private static final long START_TIMEOUT_NS = 3_000_000_000L;

    private final InetAddress server;
    private final int port;
    private final String token;
    private final DatagramSocket socket;
    private volatile boolean running = true;
    private AudioTrack track;
    private boolean metadata;
    private int sampleRate = 48_000;
    private int channels = 2;
    private int expectedSequence = -1;
    private long lastHelloNs;
    private long lastPingNs;
    private long lastPacketNs;
    private long statsStartNs;
    private int statsPackets;
    private long statsBytes;

    AudioReceiver(String host, int port, String token) throws IOException {
        super("tablet-display-audio");
        this.server = InetAddress.getByName(host);
        this.port = port;
        this.token = token;
        socket = new DatagramSocket();
        socket.setReceiveBufferSize(1 << 20);
        socket.setSoTimeout(200);
    }

    @Override public void run() {
        byte[] buffer = new byte[2048];
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        byte[] hello = ("HELLO " + token + "\n").getBytes(StandardCharsets.UTF_8);
        byte[] ping = "PING\n".getBytes(StandardCharsets.UTF_8);
        long start = System.nanoTime();
        while (running) {
            long now = System.nanoTime();
            if (!metadata && now - lastHelloNs >= HELLO_INTERVAL_NS) {
                send(hello);
                lastHelloNs = now;
            }
            if (metadata && now - lastPingNs >= PING_INTERVAL_NS) {
                send(ping);
                lastPingNs = now;
            }
            if (!metadata && now - start >= START_TIMEOUT_NS) {
                Log.i(TAG, "No audio stream; audio stays disabled");
                break;
            }
            packet.setLength(buffer.length);
            try {
                socket.receive(packet);
            } catch (SocketTimeoutException timeout) {
                continue;
            } catch (IOException error) {
                if (running) Log.w(TAG, "Audio receive", error);
                break;
            }
            int length = packet.getLength();
            if (length < 1) continue;
            if (length >= 4 && buffer[0] == 'T' && buffer[1] == 'D'
                    && buffer[2] == 'A' && buffer[3] == 'U') {
                handleAudio(buffer, length);
            } else {
                handleControl(new String(buffer, 0, length, StandardCharsets.UTF_8));
            }
        }
        close();
    }

    private void handleControl(String text) {
        String message = text.trim();
        if (!message.startsWith("AMETA ")) return;
        String[] fields = message.split("\\s+");
        if (fields.length < 3) return;
        try {
            int rate = Integer.parseInt(fields[1]);
            int channelCount = Integer.parseInt(fields[2]);
            if (rate < 8_000 || rate > 192_000) return;
            if (channelCount < 1 || channelCount > 2) return;
            sampleRate = rate;
            channels = channelCount;
            metadata = true;
            lastPacketNs = System.nanoTime();
            createTrack();
            if (track != null) send("READY\n".getBytes(StandardCharsets.UTF_8));
            Log.i(TAG, "Audio " + sampleRate + "Hz " + channels + "ch");
        } catch (NumberFormatException ignored) {
            // Ignore malformed control packets.
        }
    }

    private void createTrack() {
        if (track != null) return;
        int channelMask = channels == 1
                ? AudioFormat.CHANNEL_OUT_MONO
                : AudioFormat.CHANNEL_OUT_STEREO;
        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(channelMask)
                .build();
        int minBuffer = AudioTrack.getMinBufferSize(sampleRate, channelMask,
                AudioFormat.ENCODING_PCM_16BIT);
        if (minBuffer <= 0) minBuffer = 4096;
        AudioTrack built = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(format)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(Math.max(minBuffer, 4096))
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build();
        built.play();
        track = built;
        statsStartNs = System.nanoTime();
    }

    private void handleAudio(byte[] data, int length) {
        if (track == null || length < 16) return;
        int sequence = ((data[4] & 0xFF) << 24) | ((data[5] & 0xFF) << 16)
                | ((data[6] & 0xFF) << 8) | (data[7] & 0xFF);
        if (expectedSequence >= 0 && sequence != expectedSequence) {
            // Audio has no retransmission; let the AudioTrack ride through the
            // gap instead of waiting for a packet that will not arrive.
            Log.w(TAG, "Audio sequence gap " + expectedSequence + " -> " + sequence);
        }
        expectedSequence = sequence + 1;
        int payload = (length - 16) & ~1;
        if (payload <= 0) return;
        int written = track.write(data, 16, payload, AudioTrack.WRITE_BLOCKING);
        if (written < 0) {
            Log.w(TAG, "AudioTrack write failed: " + written);
            return;
        }
        lastPacketNs = System.nanoTime();
        statsPackets++;
        statsBytes += written;
        long elapsed = lastPacketNs - statsStartNs;
        if (elapsed >= 5_000_000_000L) {
            Log.i(TAG, String.format(java.util.Locale.US,
                    "audio stats packets=%.1f/s kbps=%.1f",
                    statsPackets / (elapsed / 1_000_000_000.0),
                    statsBytes * 8 / (elapsed / 1_000_000_000.0) / 1000.0));
            statsStartNs = lastPacketNs;
            statsPackets = 0;
            statsBytes = 0;
        }
    }

    private void send(byte[] data) {
        try {
            socket.send(new DatagramPacket(data, data.length, server, port));
        } catch (IOException ignored) {
            // The video path is independent; audio simply stays silent.
        }
    }

    @Override public void close() {
        running = false;
        socket.close();
        AudioTrack current = track;
        track = null;
        if (current != null) {
            try { current.pause(); } catch (Exception ignored) {}
            try { current.flush(); } catch (Exception ignored) {}
            try { current.stop(); } catch (Exception ignored) {}
            current.release();
        }
    }
}
