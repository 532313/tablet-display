package dev.local.tabletdisplay;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;

/** Pure-Java parsing helpers for the tablet video protocol. */
public final class VideoProtocol {
    private VideoProtocol() {}

    public static void readHttpHeader(InputStream stream) throws IOException {
        int count = 0, matched = 0;
        byte[] end = {'\r', '\n', '\r', '\n'};
        StringBuilder first = new StringBuilder();
        while (count++ < 8192) {
            int value = stream.read();
            if (value < 0) throw new IOException("Connection closed");
            if (first.length() < 15) first.append((char) value);
            matched = value == end[matched] ? matched + 1 : (value == '\r' ? 1 : 0);
            if (matched == 4) {
                if (!first.toString().startsWith("HTTP/1.1 200")) {
                    throw new IOException("HTTP error: " + first);
                }
                return;
            }
        }
        throw new IOException("HTTP header too large");
    }

    public static void validateVideoSize(int width, int height) throws IOException {
        if (width < 640 || width > 4096 || height < 480 || height > 4096) {
            throw new IOException("Invalid video size");
        }
    }

    public static void validateFrameLength(int length) throws IOException {
        if (length <= 0 || length > 4 * 1024 * 1024) {
            throw new IOException("Invalid frame length " + length);
        }
    }

    public static Frame readFrame(DataInputStream input) throws IOException {
        int flag = input.readUnsignedByte();
        int length = input.readInt();
        validateFrameLength(length);
        byte[] data = new byte[length];
        input.readFully(data);
        return new Frame(flag, data);
    }

    public static ArrayList<byte[]> splitNals(byte[] bytes) {
        ArrayList<byte[]> result = new ArrayList<>();
        int start = -1;
        for (int i = 0; i + 3 < bytes.length; i++) {
            if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1) {
                if (start >= 0 && i > start) {
                    result.add(java.util.Arrays.copyOfRange(bytes, start, i));
                }
                start = i;
                i += 3;
            }
        }
        if (start >= 0) {
            result.add(java.util.Arrays.copyOfRange(bytes, start, bytes.length));
        }
        return result;
    }

    public static final class Frame {
        public final int flag;
        public final boolean keyframe;
        public final boolean formatChange;
        public final byte[] data;

        Frame(int flag, byte[] data) {
            this.flag = flag;
            this.keyframe = flag == 1;
            this.formatChange = flag == 2;
            this.data = data;
        }
    }
}
