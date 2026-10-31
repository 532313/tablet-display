package dev.local.tabletdisplay;

import android.util.Log;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Reports the tablet's current orientation to the Mac over the local HTTP API. */
final class OrientationReporter extends Thread {
    private static final String TAG = "TabletDisplayOrientation";

    private final String host;
    private final int port;
    private final String token;
    private final Object lock = new Object();
    private Boolean desired;
    private Boolean reported;
    private long nextAttemptMs;
    private volatile boolean running = true;

    OrientationReporter(String host, int port, String token, boolean portrait) {
        super("tablet-display-orientation");
        this.host = host;
        this.port = port;
        this.token = token;
        this.desired = portrait;
    }

    void update(boolean portrait) {
        synchronized (lock) {
            desired = portrait;
            nextAttemptMs = 0;
            lock.notifyAll();
        }
    }

    void close() {
        running = false;
        interrupt();
    }

    @Override public void run() {
        while (running) {
            Boolean target = null;
            synchronized (lock) {
                while (running) {
                    long now = System.currentTimeMillis();
                    if (desired != null && !desired.equals(reported) && now >= nextAttemptMs) {
                        target = desired;
                        break;
                    }
                    try {
                        lock.wait(500);
                    } catch (InterruptedException ignored) {
                        if (!running) return;
                    }
                }
            }
            if (target == null) continue;
            if (post(target)) {
                synchronized (lock) { reported = target; }
            } else {
                synchronized (lock) { nextAttemptMs = System.currentTimeMillis() + 1000; }
            }
        }
    }

    private boolean post(boolean portrait) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL("http://" + host + ":" + port + "/orientation");
            connection = (HttpURLConnection) url.openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(1500);
            // The Mac waits for the virtual display/capture switch before replying.
            connection.setReadTimeout(7000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json");
            if (!token.isEmpty()) {
                connection.setRequestProperty("Authorization", "Bearer " + token);
            }
            byte[] body = ("{\"portrait\":" + portrait + "}").getBytes(StandardCharsets.UTF_8);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body);
            }
            int code = connection.getResponseCode();
            if (code == 204 || code == 200) return true;
            if (code == 409 || code == 401 || code == 404) {
                Log.w(TAG, "Orientation endpoint returned " + code);
            }
        } catch (Exception error) {
            Log.d(TAG, "Orientation report pending: " + error.getMessage());
        } finally {
            if (connection != null) connection.disconnect();
        }
        return false;
    }
}
