# MetaFusion API Gateway

> **本仓库不再持有生效的路由矩阵。** 唯一生效的矩阵在主仓库 MetaFusion 的 `deploy/nginx.conf`
> （compose 的 `gateway` 服务把它挂进容器），归属表在 `docs/architecture/service-split-migration.md` §2，
> 两者的一致性由主仓库的 `scripts/check_gateway_matrix.py` 强制。
> 本仓库此前那份 `nginx.conf` 是切流前（P0–P3）的迁移期矩阵，账号/互动/OAuth 前缀当时仍指向单体
> `catalog:8080`（而线上服务名是 `backend`，根本没有 `catalog` 这个服务），照它部署会把账号前缀打回目录。
> 它现在放在 `examples/pre-cutover/`，只作历史追溯，**不要挂进任何容器**。

## 仓库里现在有什么

| 路径 | 作用 |
| --- | --- |
| `scripts/cutover-check.sh` | 切流/回滚自检：逐服务健康 + 逐前缀分流核对（判据是每个服务的 `X-MetaFusion-Service` 响应头） |
| `examples/pre-cutover/` | 切流前的矩阵与共用反代头样例，**不参与部署** |

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

## 改路由归属时的顺序

1. 改主仓库 `deploy/nginx.conf`（每个前缀一行 `set $x_upstream`，切流/回滚只改这一行）；
2. 同步主仓库 `docs/architecture/service-split-migration.md` §2 的归属表；
3. 在主仓库跑 `python scripts/check_gateway_matrix.py`（不一致即 FAIL，含"文档归给谁、矩阵指向谁"的比对）；
4. 部署后用本仓库的 `GATEWAY=<host> ./scripts/cutover-check.sh` 逐前缀复核标记。

`/api/users/{id}/favorites` 与用户资料同前缀，因此网关用精确正则 `^/api/users/[^/]+/favorites$` 单独分流，
其余 `/api/users/*` 仍归目录服务——这类"同前缀不同归属"的规则只在主仓库矩阵里有唯一一份。

> 本仓库只做网关与切流自检，不承载业务；聚合各服务 OpenAPI 是后续目标，当前 `/api/openapi.json` 由 catalog 提供。
