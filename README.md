# MetaFusion API Gateway

MetaFusion 微服务生态统一边缘网关、反向代理调度与全域 OpenAPI 聚合中心。

## 🌐 路由映射矩阵

网关对外暴露单一统一域名（如 `https://findverse.cc`），负责将流量透明分流至各自治子系统：

| 路由路径 | 目标微服务 | 仓库地址 | 协议与功能 |
|---|---|---|---|
| `/api/catalog/*` | `metafusion-catalog` | [MoeclubM/MetaFusion](https://github.com/MoeclubM/MetaFusion) | **核心主项目**，实体增删改查、动态定义、图谱 |
| `/api/auth/*` | `metafusion-auth` | [MoeclubM/metafusion-auth](https://github.com/MoeclubM/metafusion-auth) | 统一认证中心，OAuth 2.0 / OIDC / JWT |
| `/api/storage/*` | `metafusion-storage` | [MoeclubM/metafusion-storage](https://github.com/MoeclubM/metafusion-storage) | 物理对象存储、哈希校验、下载流 |
| `/api/community/*` | `metafusion-community` | [MoeclubM/metafusion-community](https://github.com/MoeclubM/metafusion-community) | 社区论坛、主题帖、楼层讨论、评分 |
| `/docs/*` | `metafusion-docs` | [MoeclubM/metafusion-docs](https://github.com/MoeclubM/metafusion-docs) | VitePress 静态文档站 |
| `/*` | `metafusion-frontend` | 前端 UI 站点 | Next.js 页面与交互渲染 |

## 🚀 启动与部署

```bash
docker build -t metafusion-api-gateway .
docker run -d --name metafusion-gateway -p 10100:80 --network metafusion-net metafusion-api-gateway
```
