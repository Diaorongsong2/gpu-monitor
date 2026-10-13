# GPU 与推理服务监控（DCGM Exporter + Prometheus + Grafana）

在一张消费级显卡（NVIDIA GeForce GTX 1650 4GB）上跑大模型推理，配套搭的 GPU 与主机监控。

覆盖 GPU 利用率 / 显存 / 温度 / 功耗 / 时钟 / XID 错误采集，以及 vLLM 推理服务的指标暴露与看板。

---

## 一、这个仓库解决什么问题

在小显存单卡上跑 LLM 推理，有几个问题是纯靠 `nvidia-smi` 盯着解决不了的：

- **显存到底被谁占了**：模型权重、KV Cache、CUDA Graph、桌面进程（Xorg）都在抢那 4GB，`nvidia-smi` 只能看到总量
- **利用率看不出来趋势**：`nvidia-smi` 是瞬时值，想知道"过去半小时卡是闲着还是在跑满"得一直敲
- **掉卡 / 硬件异常没有告警**：XID 错误这类问题，出的时候服务已经挂了，事后才去查
- **怀疑是 GPU 问题还是主机问题**：分不清是卡慢还是 CPU / 内存拖后腿

做法就是把 GPU 指标（DCGM Exporter）和主机指标（node-exporter）都拉进 Prometheus，
用 Grafana 放在同一处对着看，这样上面四个问题都能直接读出来。

## 二、真实环境长什么样

和常见的"单机跑一套 compose"不同，这套环境是**跨机器**的：GPU 在 Windows 宿主机上，
Prometheus 和 Grafana 跑在同网段的 K8s 集群里，靠 Prometheus Operator 的
`additionalScrapeConfigs` 把宿主机上的两个 exporter 抓进来。

```
┌─ Windows 宿主机 ──────────────────────────────────────┐
│   NVIDIA GeForce GTX 1650 4GB   (Driver 595.97)       │
│        │ NVML                                         │
│        ▼                                              │
│   Docker Desktop                                      │
│    ├─ nvidia-dcgm-exporter    :9400                   │
│    └─ node-exporter           :9100                   │
└──────────────────┬────────────────────────────────────┘
                   │  192.168.44.1（VMnet8 里宿主机的地址）
                   │  http，30s 一次
                   ▼
┌─ K8s 集群  192.168.44.20 / .21 / .22 ─────────────────┐
│   monitoring 命名空间（kube-prometheus 0.12）          │
│    ├─ Prometheus   抓集群内指标 + 上面两个外部 target   │
│    └─ Grafana      官方 NVIDIA DCGM Exporter Dashboard │
└───────────────────────────────────────────────────────┘
```

| 部分 | 位置 | 说明 |
|---|---|---|
| GPU 与 exporter | Windows 宿主机 | GTX 1650 4GB；Docker Desktop 跑 dcgm-exporter `:9400`、node-exporter `:9100` |
| `192.168.44.1` | VMware VMnet8 | 从集群节点看过去的宿主机地址，外部 target 填的就是它 |
| Prometheus / Grafana | K8s 集群 `monitoring` | kube-prometheus 0.12（Operator 托管），CR 名 `k8s` |
| 抓取配置 | Secret `additional-scrape-configs` | 见 `k8s/` 目录，job 名 `wsl-node-exporter` / `wsl-nvidia-dcgm`，均 `up` |
| Grafana 看板 | Grafana Web UI | 官方 [NVIDIA DCGM Exporter Dashboard](https://grafana.com/grafana/dashboards/12239/)（ID 12239，uid `Oxed_c6Wz`） |

截图：`docs/06-grafana-dcgm-official-dashboard.png`（看板实时数据）、`docs/07-grafana-dcgm-metric-names.png`（指标名浏览）。

> 顺带一提：宿主机上还有一个没起名字的 `node-exporter`（容器名 `jovial_shamir`），是早期重复起的，没有端口映射，属于冗余，`docker rm -f` 掉即可。

## 三、两种搭法

### 方式 A：单机 docker compose（本仓库提供，适合复现）

`docker-compose.yml` 把 dcgm-exporter / node-exporter / Prometheus / Grafana 四件套一次起完，
不需要 K8s，适合在单台有卡的机器上跑通整条链路。看板会由 provisioning 自动加载。

### 方式 B：K8s 侧抓取（真实环境用的这种）

集群里已经有 kube-prometheus 的话，不用再装一套 Prometheus，直接让 Operator 管的那套去抓外部 exporter：

```bash
# 1. 建 Secret
kubectl apply -f k8s/additional-scrape-configs.yaml

# 2. 把 Prometheus CR 指过去（Operator 会自动重建 Prometheus Pod 生效）
kubectl -n monitoring patch prometheus k8s --type merge -p \
  '{"spec":{"additionalScrapeConfigs":{"name":"additional-scrape-configs","key":"prometheus-additional.yaml"}}}'

# 3. 验证
kubectl -n monitoring get prometheus k8s -o jsonpath='{.spec.additionalScrapeConfigs}'; echo
curl -s http://127.0.0.1:19090/api/v1/targets --data-urlencode 'state=active' # 需要先 port-forward svc/prometheus-k8s
```

**注意**：不要直接改 Operator 生成的那个 Secret（`prometheus-k8s`），改完会被 reconcile 覆盖回来。
自定义抓取目标的唯一正规入口就是 CR 的 `spec.additionalScrapeConfigs`。

## 四、指标清单（实测）

下面是 GTX 1650 上从 `:9400/metrics` 实际抓到的**全部 16 个指标**（原始输出见 `docs/08-dcgm-metrics-raw.txt`）。
客户端访问的是 `http://192.168.44.1:9400/metrics`。

| 指标 | 含义 | 实测值（空闲） | 消费卡上是否有意义 |
|---|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | GPU 利用率 % | 0 | 有 |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | 显存带宽利用率 % | 0 | 有 |
| `DCGM_FI_DEV_FB_USED` | 已用显存 MB | 3482 | 有 |
| `DCGM_FI_DEV_FB_FREE` | 剩余显存 MB | 452 | 有 |
| `DCGM_FI_DEV_GPU_TEMP` | GPU 核心温度 °C | 52 | 有 |
| `DCGM_FI_DEV_POWER_USAGE` | 瞬时功耗 W | 3.421 | 有，但读数精度很粗 |
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | 自开机累计能耗 mJ | 17917535 | 有 |
| `DCGM_FI_DEV_SM_CLOCK` | SM 核心频率 MHz | 300 | 有 |
| `DCGM_FI_DEV_MEM_CLOCK` | 显存频率 MHz | 405 | 有 |
| `DCGM_FI_DEV_ENC_UTIL` | 编码器利用率 % | 0 | 有（没任务时恒 0） |
| `DCGM_FI_DEV_DEC_UTIL` | 解码器利用率 % | 0 | 同上 |
| `DCGM_FI_DEV_XID_ERRORS` | 最近一次 XID 错误码 | 0 | 有，非 0 必须查 |
| `DCGM_FI_DEV_PCIE_REPLAY_COUNTER` | PCIe 重传计数 | 0 | 恒 0 属正常 |
| `DCGM_FI_DEV_MEMORY_TEMP` | 显存温度 °C | 0 | ✗ 消费卡不上报，恒 0 |
| `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` | NVLink 带宽计数 | 0 | ✗ GTX 1650 没有 NVLink |
| `DCGM_FI_DEV_VGPU_LICENSE_STATUS` | vGPU 授权状态 | 0 | ✗ 非 vGPU 环境 |

两个读数据时要注意的点：

- `FB_USED` + `FB_FREE` = 3934 MB，卡标称 4096 MB，差的约 160 MB 是驱动自己留的，不是异常。
- 空闲时 `FB_USED` 是 3482 MB —— 这 3.4 GB 里绝大部分是 vLLM 按 `--gpu-memory-utilization 0.7` 预分配的显存池，
  不是模型权重本身（Qwen2.5-0.5B 权重才 1 GB 左右）。

## 五、仓库结构

```
docker-compose.yml                                  方式 A：四件套一键起
prometheus/prometheus.yml                           方式 A 的抓取配置
grafana/provisioning/datasources/prometheus.yml     数据源（uid 固定为 prometheus，自动配置）
grafana/provisioning/dashboards/dashboards.yml      看板自动加载
grafana/dashboards/
  dcgm-exporter-official.json                       官方 12239 看板（真实环境用的就是它，已替换好数据源引用）
  gpu-node-overview.json                            精简版看板：把 GPU 与主机指标并在一张上
k8s/
  additional-scrape-configs.yaml                    方式 B：让集群 Prometheus 抓外部 exporter
  prometheus-additional.yaml                        方式 B 的抓取配置内容（真实内容）
vllm/serve-qwen2.5-0.5b.sh                          vLLM 启动脚本（含参数说明）
docs/                                               运行截图与原始数据
  01-vllm-start-qwen2.5-0.5b.png                    vLLM 启动过程
  02-vllm-api-routes-and-ready.png                  路由注册与 startup complete
  03-containers-dcgm-node-exporter.png              容器运行状态
  04-nvidia-smi-gtx1650.png                         nvidia-smi 原始输出
  05-docker-ps-a.png                                docker ps 详情
  06-grafana-dcgm-official-dashboard.png            Grafana 官方 DCGM 看板实时数据
  07-grafana-dcgm-metric-names.png                  Grafana 指标名浏览
  08-dcgm-metrics-raw.txt                           导出器原始输出（16 个指标全量）
```

## 六、怎么复现

> 前置：装好 Docker、NVIDIA 驱动和 **nvidia-container-toolkit**（不装的话容器里看不到卡）。

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

**只想快速看 GPU 指标**，不装 Prometheus / Grafana 也行（这也是宿主机上实际的起法）：

```bash
docker run -d --gpus all --name nvidia-dcgm-exporter \
  -p 9400:9400 -e NVIDIA_VISIBLE_DEVICES=all \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
curl -s localhost:9400/metrics | grep DCGM_FI_DEV
```

## 七、踩过的坑

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

**3. 官方看板的 "GPU Power Total" 单卡场景下会被误读**

那个表盘的表达式是 `sum(DCGM_FI_DEV_POWER_USAGE)`。单卡时左边那个 `sum` 会把**时间区间里所有采样点**
加起来，而不是算物理总功耗 —— 看板截图里它显示 70.4 W，可同一时刻旁边的 "GPU Power Usage" 曲线只有 3.35 W 左右。

算一下就对上了：5 分钟区间、15 秒一个采样点 = 21 个点，21 × 3.35 ≈ 70.4 W。
这个表盘本来是为多卡整机总功耗设计的，单卡看千万别当成"卡已经在跑满 70 W"。

**4. 消费级卡的指标"有名字但没意义"**

`DCGM_FI_DEV_MEMORY_TEMP`、`DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL`、`DCGM_FI_DEV_VGPU_LICENSE_STATUS`
这些在 GTX 1650 上都是有 series 的（不会报错），但值恒为 0。
所以看板不会"空"，得靠指标本身的含义去判断有没有参考价值 —— NVLink 带宽恒 0 不是故障，是这张卡根本没有 NVLink。

**5. 跨网段抓取：target 要填宿主机的真实地址，别填 WSL 的**

一开始把 target 写成了 `172.28.179.4:9400`（那是 Windows 上 WSL 虚拟网卡的地址），
集群里的 Prometheus 压根路由不过去，两个 target 一直 `context deadline exceeded`。
换成 `192.168.44.1`（VMnet8 里宿主机的地址）后立刻 `up`。

排查思路简单说：先在节点上 `curl http://<target>/metrics`，通不通一眼就分得清是网络问题还是配置问题。

**6. 容器里看不到卡时，`dcgm-exporter` 起来了也是 0 指标**

不装 `nvidia-container-toolkit`、或者 `docker run` 漏了 `--gpus all` 时，
容器能正常启动、`:9400/metrics` 也能访问，但里面一个 `DCGM_FI_*` 都没有。
判断方法：`docker inspect <容器> --format '{{json .HostConfig.DeviceRequests}}'`，
正常应该能看到 `"Capabilities":[["gpu"]]`。

## 八、后续可以做的

- 加 Alertmanager，对 `DCGM_FI_DEV_XID_ERRORS > 0`、显存占用超阈值、GPU 温度过高发告警
- 把推理服务的请求延迟（vLLM 的 `/metrics`）也接进来，和 GPU 利用率放一起看，能定位"是卡慢还是请求排队"
- 多卡场景下用 `gpu` label 分卡展示；`GPU Power Total` 那个表盘也就能正常读数了
- 消费卡上的 `DCGM_FI_DEV_GPU_UTIL` 只有"是否在算"，没有 SM 占用 / 张量核占用这类细分，
  官方看板里的 Tensor Core Utilization 面板在这张卡上是空的（需要 `DCGM_FI_PROF_*`，数据中心卡才给）
