# GPU 与推理服务监控（DCGM Exporter + Prometheus + Grafana）

在**单张消费级显卡**（NVIDIA GeForce GTX 1650 4GB）上跑大模型推理，配套搭建的 GPU 与主机监控。

覆盖：GPU 利用率 / 显存 / 温度 / 功耗 / XID 错误采集，以及 vLLM 推理服务的指标暴露与看板。

---

## 一、这个仓库解决什么问题

在小显存单卡上跑 LLM 推理，有几个问题是纯靠 `nvidia-smi` 盯着解决不了的：

- **显存到底被谁占了**：模型权重、KV Cache、CUDA Graph、桌面进程（Xorg）都在抢那 4GB，`nvidia-smi` 只能看到总量
- **利用率看不出来趋势**：`nvidia-smi` 是瞬时值，想知道"过去半小时卡是闲着还是在跑满"得一直敲
- **掉卡 / 硬件异常没有告警**：XID 错误这类问题，出的时候服务已经挂了，事后才去查
- **怀疑是 GPU 问题还是主机问题**：分不清是卡慢还是 CPU / 内存拖后腿

做法就是把 GPU 指标（DCGM Exporter）和主机指标（node-exporter）都拉进 Prometheus，
用 Grafana 放在同一张看板上对着看，这样上面四个问题都能直接读出来。

## 二、架构与组件

```
vLLM (OpenAI 兼容 API, :8000)
        │  显存 / 利用率由同一张卡产生
        ▼
   NVIDIA GPU (GTX 1650 4GB)
        │  NVML
        ▼
DCGM Exporter (:9400) ──┐
                        ├──► Prometheus (:9090) ──► Grafana (:3000)
node-exporter (:9100) ──┘
```

| 组件 | 版本 / 端口 | 作用 |
|---|---|---|
| vLLM | 0.18.0，`:8000` | 推理服务，OpenAI 兼容 API |
| DCGM Exporter | `3.3.5-3.4.0-ubuntu22.04`，`:9400` | 从 NVML 采集 GPU 指标 |
| node-exporter | latest，`:9100` | 主机 CPU / 内存 / 磁盘 / 网络 |
| Prometheus | latest，`:9090` | 指标存储与查询 |
| Grafana | latest，`:3000` | 看板，自动导入并配置数据源 |

**实测环境**：Ubuntu 22.04 / NVIDIA Driver 595.97 / CUDA 13.2 / Docker + nvidia-container-toolkit

**采集的 GPU 指标**：

| 指标 | 含义 |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | GPU 利用率 |
| `DCGM_FI_DEV_FB_USED` / `_FREE` | 显存已用 / 剩余 |
| `DCGM_FI_DEV_GPU_TEMP` | 温度 |
| `DCGM_FI_DEV_POWER_USAGE` | 功耗 |
| `DCGM_FI_DEV_XID_ERRORS` | XID 错误码，非 0 说明硬件层面有异常 |

## 三、仓库结构

```
docker-compose.yml                                四件套一键起（dcgm-exporter / node-exporter / prometheus / grafana）
prometheus/prometheus.yml                         抓取配置
grafana/provisioning/datasources/prometheus.yml   数据源（自动配置）
grafana/provisioning/dashboards/dashboards.yml    看板自动加载
grafana/dashboards/gpu-node-overview.json         看板：GPU 利用率 / 显存 / 温度 / 功耗 / XID / 主机 CPU、内存
vllm/serve-qwen2.5-0.5b.sh                        vLLM 启动脚本（含参数说明）
docs/                                             运行截图
  01-vllm-start-qwen2.5-0.5b.png                  vLLM 启动过程
  02-vllm-api-routes-and-ready.png                路由注册与 startup complete
  03-containers-dcgm-node-exporter.png            容器运行状态
  04-nvidia-smi-gtx1650.png                       nvidia-smi 原始输出
  05-docker-ps-a.png                              docker ps 详情
```

## 四、怎么复现

> 前置：装好 Docker、NVIDIA 驱动和 **nvidia-container-toolkit**（不装的话容器里看不到 GPU）。

```bash
# 1. 起监控栈
docker compose up -d

# 2. 确认指标能采到
curl -s http://localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
curl -s http://localhost:9100/metrics | head

# 3. 起推理服务（另开一个终端）
bash vllm/serve-qwen2.5-0.5b.sh

# 4. 验证推理服务
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

看板入口：Grafana `http://<host>:3000`，默认账号 `admin` / `admin`（首次登录会要求改密码）。
数据源和看板都通过 provisioning 自动加载，不用手工导入。

**只想快速看 GPU 指标**，不装 Prometheus / Grafana 也行：

```bash
docker run -d --gpus all --name nvidia-dcgm-exporter \
  -p 9400:9400 -e NVIDIA_VISIBLE_DEVICES=all \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
curl -s localhost:9400/metrics | grep DCGM_FI_DEV
```

## 五、踩过的坑

**1. GTX 1650 不支持 bfloat16**

vLLM 启动时会打 WARNING 并自动回落到 float16，属正常现象，不用管：

```
WARNING Your device 'NVIDIA GeForce GTX 1650' (with compute capability 7.5)
        doesn't support torch.bfloat16. Falling back to torch.float16 for compatibility.
```

**2. 4GB 显存要把参数压下来**

默认参数直接 OOM。三个关键项：

| 参数 | 值 | 作用 |
|---|---|---|
| `--gpu-memory-utilization` | `0.7` | 只占 70% 显存，留余量给 Xorg / 桌面进程 |
| `--max-model-len` | `1024` | 压低 KV Cache 上限，**这是省显存最有效的一项** |
| `--enforce-eager` | — | 关闭 CUDA Graph 捕获，少占显存、启动更快，代价是吞吐略降 |

**3. 消费级卡的指标不全**

`DCGM_FI_DEV_ECC_*`、MIG 相关、NVLink 相关这些企业卡才有的指标，
在 GTX 1650 上采不到（看板里对应面板会是空值），属预期行为，不是配置问题。

## 六、后续可以做的

- 加 Alertmanager，对 `DCGM_FI_DEV_XID_ERRORS > 0`、显存占用超阈值、GPU 温度过高发告警
- 把推理服务的请求延迟（vLLM 的 `/metrics`）也接进来，和 GPU 利用率放一起看，能定位"是卡慢还是请求排队"
- 多卡场景下用 `DCGM_FI_DEV_GPU_UTIL` 的 `gpu` label 分卡展示
