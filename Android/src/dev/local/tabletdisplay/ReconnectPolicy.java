package dev.local.tabletdisplay;

/** Bounded exponential backoff for the video connection. */
public final class ReconnectPolicy {
    private ReconnectPolicy() {}

    public static final long INITIAL_DELAY_MS = 500L;
    public static final long MAX_DELAY_MS = 5_000L;

    public static long delayMillis(int attempt) {
        if (attempt <= 0) return INITIAL_DELAY_MS;
        int shift = Math.min(attempt, 4);
        return Math.min(INITIAL_DELAY_MS << shift, MAX_DELAY_MS);
    }

    public static boolean shouldRetry(boolean running) {
        return running;
    }
}
