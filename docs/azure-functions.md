# 部署到 Azure（Linux App Service）

> **注意**：原计划使用 Azure Functions Custom Handler，但 Flex Consumption 计划不支持 Custom Handler，Premium 计划需要配额提升。最终改为 **Linux App Service B1**，直接通过 startup script 运行 Go 二进制。

## 架构

```
Azure Linux App Service (B1)
  └─ 容器 (DOTNETCORE:8.0 占位镜像)
      ├─ startup.sh → chmod +x hubproxy && exec ./hubproxy
      ├─ hubproxy（Go 二进制，监听 :8080）
      ├─ config.toml（配置文件）
      └─ dist/（前端 SPA，嵌入 Go 二进制）
```

**关键点**：
- Azure App Service Linux 强制要求进程监听 **8080 端口**（通过环境变量 `WEBSITES_PORT=8080` 或 `SERVER_PORT=8080`）
- startup command 使用独立 `startup.sh` 脚本避免 oryx 引号解析问题
- zip 解压后 `hubproxy` 丢失可执行权限，startup.sh 内部 `chmod +x` 解决

## 前提条件

1. Azure 订阅中已创建 **Linux App Service**（B1 或以上）
2. 已绑定自定义域名 `hubproxy.khbit.cn`（CNAME + Azure 门户绑定）
3. GitHub Secrets/Variables 已配置

### GitHub 配置

| 类型 | 名称 | 说明 |
|------|------|------|
| Secret | `AZURE_WEBAPP_PUBLISH_PROFILE` | App Service 发布配置文件（从 Azure Portal 下载） |
| Variable | `AZURE_RESOURCE_GROUP` | 资源组名（如 `Hubproxy_group`） |
| Variable | `AZURE_WEBAPP_NAME` | App Service 名称（如 `HubproxyApp`） |

> **注意**：`AZURE_FUNCTIONAPP_PUBLISH_PROFILE` 是旧 Function App 的配置，已废弃。

## 一、部署流程

```
push main → Actions 触发
  → npm ci + npm run build (前端)
  → CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build (Go 二进制)
  → 组装 deploy/ (hubproxy + config.toml + startup.sh)
  → zip 打包
  → 上传 Actions Artifact（始终）
  → 可选创建 GitHub Release
  → Azure/webapps-deploy 部署
```

## 二、手动触发

Actions → Deploy to Azure App Service → **Run workflow**：

| 输入项 | 说明 |
|--------|------|
| `version` | 版本号，默认自动生成 |
| `create_release` | 勾选创建 GitHub Release 附带部署包 |

### 自动部署失败时

1. Actions → 失败的 run → 底部 **Artifacts** → 下载 `hubproxy-appservice-<版本>.zip`
2. Azure Portal → App Service → **部署中心** → 上传 zip

## 三、本地构建（可选）

```powershell
# 构建 App Service 部署包
cd web && npm ci && npm run build; cd ..
cd src && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -trimpath -o hubproxy .; cd ..
mkdir -p deploy
cp src/hubproxy deploy/
cp src/config.toml deploy/
cp build/azure-functions/startup.sh deploy/
cd deploy && zip -r ../hubproxy-appservice.zip .
```

## 四、注意事项

### 端口要求

| 环境 | 端口 | 说明 |
|------|------|------|
| **Azure App Service** | `8080` | 强制要求，通过 `SERVER_PORT=8080` 环境变量 |
| **本地/其他平台** | `5000` | 默认值 |

### 有状态功能

限流器和 Token 缓存是内存级的，单实例部署正常。如需多实例需考虑外部存储。

### `config.toml` 路径

App Service 中 `config.toml` 位于 `/home/site/wwwroot/config.toml`（与 `hubproxy` 同目录），或通过 `CONFIG_PATH` 环境变量指定。
