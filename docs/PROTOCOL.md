# 传输协议

默认端口 `9137`（HTTP/1.1）；直连模式另有 UDP-RTP `9138`。均为明文传输，仅建议在可信局域网使用。

## 鉴权

`/video`、`/input`、`/pointer`、`/orientation` 需要：

```http
Authorization: Bearer <token>
```

token 每次运行随机生成（或 `--token` 指定），通过 ADB intent 传给平板。
`/` 和 `/health` 不需要鉴权。

## `GET /video`

响应头之后依次发送三个大端 `UInt32`：

```text
width, height, fps
```

随后是连续帧：

```text
1 byte  keyframe (0/1)
4 bytes big-endian length
N bytes H.264 Annex-B data
```

关键帧包含 SPS/PPS。连接建立后服务端从最近关键帧开始发送。

## UDP-RTP 视频（直连模式）

直连模式下 Mac 额外监听 UDP `9138`，平板优先走 RTP；ADB 隧道或 UDP 失败时回退到 `GET /video`。

平板到 Mac 的控制报文为 UTF-8 文本：

```text
HELLO <token>
     鉴权并注册 UDP 源地址
KEYFRAME
          请求新的 IDR
PING
              每 1 秒心跳，5 秒无心跳服务端停止发送
```

Mac 到平板的控制报文：

```text
META <width> <height> <fps>

```

随后是标准 RTP：

- 版本 2，payload type 96
- 90kHz 时间戳，每个 access unit 一个时间戳
- marker 位标记一个 access unit 的最后一个 RTP 包
- SSRC 每次运行随机
- H.264 单 NAL 或 FU-A（MTU 友好的 1200 字节 payload）
- 关键帧包含 SPS/PPS

当前 UDP 层没有 FEC/NACK：检测到 RTP 序列号缺口时，平板丢弃损坏帧并请求新 IDR。UDP 握手/首帧超时 2 秒则回退 TCP。token 只做鉴权，不提供加密。

## `POST /orientation`

请求体：

```json
{"portrait":true}
```

Mac 会等待显示/采集切换完成再回复：

- `204 No Content`：切换成功，或当前已经处于目标方向
- `409 Conflict`：切换失败或另一方向切换正在进行

Android 收到非 204 会按退避重试，避免“已上报但实际未切换”的静默失败。

## `GET /input`

长连接。每个触摸事件 9 字节：

```text
1 byte  phase: 0=move, 1=down, 2=drag, 3=up
4 bytes big-endian Float32 x (0...1)
4 bytes big-endian Float32 y (0...1)
```

## `POST /pointer`

调试接口，JSON：

```json
{"x":0.5,"y":0.5,"phase":"down"}
```

`phase` 支持 `down`、`move`、`drag`、`up`。

## `GET /health`

返回 `ready` 或 `waiting-for-frame`，用于本机健康检查。

## 超时与重连

- 服务端读取请求头和请求体有 10 秒总超时；超时或迟迟不发数据的连接会被关闭。
- 服务端发送超时 5 秒；采集停止自动重启。
- `/input` 连接断开时，如果服务端仍处于按下/拖动状态，会自动补发一次 `up`，避免 Mac 鼠标卡在按下状态。
- 平板视频 socket 5 秒无数据会重连；重连等待从 500ms 开始指数退避，单次最长 5 秒。
- 平板断开后再次连接 `/video` 时，服务端从最近的关键帧重新开始。
