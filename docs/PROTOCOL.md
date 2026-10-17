# 传输协议

默认端口 `9137`，HTTP/1.1，明文传输；仅建议在可信局域网使用。

## 鉴权

`/video`、`/input`、`/pointer` 需要：

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
