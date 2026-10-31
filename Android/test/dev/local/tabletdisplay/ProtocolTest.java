package dev.local.tabletdisplay;

import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;

/** JVM-only tests for the Android protocol/reconnect helpers. */
public final class ProtocolTest {
    private ProtocolTest() {}

    public static void main(String[] args) throws Exception {
        testHttpHeader();
        testVideoSize();
        testFrameLength();
        testFrameReader();
        testNalSplitter();
        testReconnectPolicy();
        System.out.println("Android 协议测试通过：HTTP 头、尺寸/帧长校验、帧读取、NAL 拆分、重连退避");
    }

    private static void testHttpHeader() throws Exception {
        byte[] ok = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\nrest"
                .getBytes(StandardCharsets.US_ASCII);
        VideoProtocol.readHttpHeader(new ByteArrayInputStream(ok));

        byte[] unauthorized = "HTTP/1.1 401 Unauthorized\r\n\r\n"
                .getBytes(StandardCharsets.US_ASCII);
        expectIOException(() -> VideoProtocol.readHttpHeader(new ByteArrayInputStream(unauthorized)),
                "非 200 响应必须失败");
    }

    private static void testVideoSize() throws Exception {
        VideoProtocol.validateVideoSize(2560, 1600);
        VideoProtocol.validateVideoSize(640, 480);
        expectIOException(() -> VideoProtocol.validateVideoSize(100, 100),
                "过小的视频尺寸必须失败");
        expectIOException(() -> VideoProtocol.validateVideoSize(5000, 1600),
                "过大的视频尺寸必须失败");
    }

    private static void testFrameLength() throws Exception {
        VideoProtocol.validateFrameLength(1);
        VideoProtocol.validateFrameLength(4 * 1024 * 1024);
        expectIOException(() -> VideoProtocol.validateFrameLength(0), "0 长度必须失败");
        expectIOException(() -> VideoProtocol.validateFrameLength(4 * 1024 * 1024 + 1),
                "超过 4MB 的帧必须失败");
    }

    private static void testFrameReader() throws Exception {
        byte[] packet = {1, 0, 0, 0, 3, 10, 20, 30};
        VideoProtocol.Frame frame = VideoProtocol.readFrame(
                new DataInputStream(new ByteArrayInputStream(packet)));
        check(frame.keyframe, "关键帧标志应被解析");
        check(Arrays.equals(frame.data, new byte[]{10, 20, 30}), "帧数据应完整读取");

        byte[] format = {2, 0, 0, 0, 12, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 0, 60};
        VideoProtocol.Frame changed = VideoProtocol.readFrame(
                new DataInputStream(new ByteArrayInputStream(format)));
        check(changed.formatChange, "分辨率变更标志应被解析");
        check(!changed.keyframe, "分辨率变更不是关键帧");

        byte[] bad = {0, 0, 0, 0, 0};
        expectIOException(() -> VideoProtocol.readFrame(
                        new DataInputStream(new ByteArrayInputStream(bad))),
                "非法帧长度必须失败");
    }

    private static void testNalSplitter() {
        byte[] data = {
                0, 0, 0, 1, 0x67, 1,
                0, 0, 0, 1, 0x68, 2, 2
        };
        ArrayList<byte[]> nals = VideoProtocol.splitNals(data);
        check(nals.size() == 2, "应拆分出两个 NAL");
        check(nals.get(0).length == 6, "SPS NAL 长度应包含起始码");
        check((nals.get(0)[4] & 0x1f) == 7, "第一个 NAL 应为 SPS");
        check((nals.get(1)[4] & 0x1f) == 8, "第二个 NAL 应为 PPS");
    }

    private static void testReconnectPolicy() {
        check(ReconnectPolicy.delayMillis(0) == 500, "首次重连等待 500ms");
        check(ReconnectPolicy.delayMillis(1) == 1000, "第二次重连等待 1s");
        check(ReconnectPolicy.delayMillis(2) == 2000, "第三次重连等待 2s");
        check(ReconnectPolicy.delayMillis(3) == 4000, "第四次重连等待 4s");
        check(ReconnectPolicy.delayMillis(4) == 5000, "重连等待封顶 5s");
        check(ReconnectPolicy.delayMillis(99) == 5000, "重连等待始终封顶 5s");
        check(ReconnectPolicy.shouldRetry(true), "运行中应重连");
        check(!ReconnectPolicy.shouldRetry(false), "停止后不应重连");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    private static void expectIOException(ThrowingRunnable action, String message) {
        try {
            action.run();
        } catch (IOException expected) {
            return;
        } catch (Exception other) {
            throw new AssertionError(message + "（异常类型错误：" + other + "）", other);
        }
        throw new AssertionError(message + "（未抛出异常）");
    }
}
