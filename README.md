# MetaFusion API Gateway

MetaFusion 微服务生态的统一边缘网关：按前缀分流、限流、安全响应头。对外只暴露一个域名（如 `https://findverse.cc`）。

拆分基准与切流顺序见主仓库 [docs/architecture/service-split-migration.md](https://github.com/MoeclubM/MetaFusion/blob/main/docs/architecture/service-split-migration.md)。

## 路由矩阵（含迁移状态）

`nginx.conf` 里每个前缀只有一行 `set $x_backend ...`：**切流 = 改这一行，回滚同理**。
下表"当前指向"是今天真实生效的上游；"目标上游"是该前缀最终归属的服务。

| 前缀 | 当前指向 | 目标上游 | 状态 |
|---|---|---|---|
| `/api/catalog/*` | catalog:8080（主仓库） | catalog:8080 | ✅ 已在目标形态 |
| `/api/auth/*`、`/api/setup`、`/api/admin/users*`、`/api/oauth/*`、`/api/oidc/*`、`/api/.well-known/*` | catalog:8080 | auth:8081 | ⏳ 等 metafusion-auth 实现并验收（P3） |
| `/.well-known/*`（根路径 discovery） | auth:8081 | auth:8081 | ⏸ auth 上线后启用；当前 issuer 在 `/api` 下 |
| `/api/community/*`、`/api/records/*` | catalog:8080 | community:8083 | ⏳ 服务已实现（P2 完成），切流改成 `http://community:8083` 即可 |
| `/api/favorites/*`、`/api/users/{id}/favorites` | catalog:8080 | community:8083 | ⏳ 收藏仍在目录库（`catalog.favorites`），随账号拆分（P3）一起迁 |
| `/api/storage/*` | storage:8082 | storage:8082 | ✅ 契约已实现；等前端接入后对外启用（P1） |
| `/api/archive/*`、`/api/playback/*`、`/api/media/*` | catalog:8080 | storage:8082（退役旧前缀） | ⏳ P4 切流后下线 |
| `/api/*`（其余） | catalog:8080 | catalog:8080 | ✅ |
| `/uploads/*` | catalog:8080 | catalog:8080 | ✅ |
| `/docs/*` | docs:3001 | docs:3001 | ✅ |
| `/*` | frontend:3000 | frontend:3000 | ✅ |

`/api/users/{id}/favorites` 与用户资料同前缀，因此用精确正则 `^/api/users/[^/]+/favorites$` 单独分流，
其余 `/api/users/*` 仍然归目录。

## 启动与部署

```bash
docker build -t metafusion-api-gateway .
docker run -d --name metafusion-gateway -p 10100:80 --network metafusion-net metafusion-api-gateway
```

```bash
docker compose -f docker-compose.yml config --quiet   # 配置自检
nginx -t -c /etc/nginx/nginx.conf                     # 容器内语法自检
```

> 本仓库只做路由，不承载业务；聚合各服务 OpenAPI 是后续目标，当前 `/api/openapi.json` 由 catalog 提供。
