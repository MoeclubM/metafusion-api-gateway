# MetaFusion API Gateway

> **本仓库不再持有生效的路由矩阵。** 唯一生效的矩阵在主仓库 MetaFusion 的 `deploy/nginx.conf`
> （compose 的 `gateway` 服务把它挂进容器），归属表在 `docs/architecture/service-split-migration.md` §2，
> 两者的一致性由主仓库的 `scripts/check_gateway_matrix.py` 强制。
> 旧切流矩阵与反代样例已移除，历史可从 Git 查询；本仓不提供第二份可挂载配置。

## 仓库里现在有什么

| 路径 | 作用 |
| --- | --- |
| `scripts/cutover-check.sh` | 切流/回滚自检：逐服务健康 + 逐前缀分流核对（判据是每个服务的 `X-MetaFusion-Service` 响应头） |

原先的 `Dockerfile` 与 `docker-compose.yml` 已删除：它们会把上面那份过期矩阵打进镜像，
让"哪份矩阵在跑"重新变得不确定。需要网关镜像时用主仓库编排里的 `gateway` 服务（`nginx:1.25-alpine` + 挂载矩阵）。

## 自检怎么跑

```bash
# 1) 断言表自检：不联网、不需要 curl 之外的东西，CI 上跑这一条
./scripts/cutover-check.sh --self-check

# 2) 服务直连健康（默认 127.0.0.1 的 8080/8081/8082/8083）
./scripts/cutover-check.sh

# 3) 额外核对网关分流（每个前缀都会打印是哪个服务答复的）
GATEWAY=https://<host> ./scripts/cutover-check.sh

# 4) 额外对比新旧表行数（只在切流窗口用）
DSNS='postgres://user:pass@host:5432/db?sslmode=disable' ./scripts/cutover-check.sh
```

判定口径：**服务标记是必填断言**。早先的实现把标记写成占位符 `-`，等于只比 HTTP 状态码——
而"前缀又指回目录服务"同样返回 200，看不出事故。现在每条断言都必须写明期望的标记值，
`--self-check` 会拦下空标记与 `-`。

判定口径补充（行数对比，`DSNS` 分支）：**设了 `DSNS` 就没有静默跳过**——行数读不到、表存在性读不到、
本机没有 `psql`，一律 FAIL 并退出 1；只有“旧表已由 `deploy.sh retire` 删除”才报 SKIP，且写明原因。
SKIP 不等于通过，汇总行会把它单独计数。
## 改路由归属时的顺序

1. 改主仓库 `deploy/nginx.conf`（每个前缀一行 `set $x_upstream`，切流/回滚只改这一行）；
2. 同步主仓库 `docs/architecture/service-split-migration.md` §2 的归属表；
3. 在主仓库跑 `python scripts/check_gateway_matrix.py`（不一致即 FAIL，含"文档归给谁、矩阵指向谁"的比对）；
4. 部署后用本仓库的 `GATEWAY=<host> ./scripts/cutover-check.sh` 逐前缀复核标记。

`/api/users/*` 是同前缀多归属：`/{id}` 归账号服务，`/{id}/favorites` 与 `/{id}/stats` 归互动服务，`/{id}/contributions` 归目录服务。前三项用各自锚定的正则从目录兜底中分流；规则只在主仓库矩阵里有一份生效来源。

> 本仓库只做网关与切流自检，不承载业务；聚合各服务 OpenAPI 是后续目标，当前 `/api/openapi.json` 由 catalog 提供。
