# 部署到 Azure Functions

HubProxy 通过 Azure Functions **Custom Handler** 模式部署。Go 二进制作为子进程由 Functions Host 启动，通过 `FUNCTIONS_CUSTOMHANDLER_PORT` 环境变量获取监听端口，所有 HTTP 请求由 Host 转发到 Go 程序处理。

## 前提条件

1. 已创建 **Linux** 计划的 Azure Functions App（推荐 **Premium (EP1)** 或 **Dedicated** 计划，避免 Consumption 计划的超时限制）
2. 运行时选择 **.NET / Custom Handler**
3. GitHub Repo Secret 已配置 `AZURE_FUNCTIONAPP_PUBLISH_PROFILE`
4. GitHub Repo Variable 已配置 `AZURE_FUNCTIONAPP_NAME`（你的 Function App 名称）

## 一、Azure 门户操作

### 1. 创建 Function App（如尚未创建）

在 [Azure Portal](https://portal.azure.com) 中：

- **资源组**：选择已有或新建
- **Function App 名称**：填写你的 App 名称（例如 `hubproxy`）
- **运行时栈**：`.NET` → 版本 `8.0`（Custom Handler 不需要 .NET 运行时，但这是 Azure 要求的选项）
- **操作系统**：**Linux**（Custom Handler 仅在 Linux 上支持完整 HTTP 转发）
- **计划类型**：
  - **Premium (EP1)**：推荐，无执行超时，支持 VNet
  - **Dedicated (App Service)**：无超时，可缩放
  - ~~Consumption~~：**不推荐**，HTTP 请求超时仅 5 分钟，大文件下载会中断

### 2. 配置环境变量

在 Function App → **设置 → 环境变量** 中添加：

| 变量名 | 值 | 说明 |
|--------|-----|------|
| `WEBSITE_MAX_DYNAMIC_APPLICATION_SCALE_OUT` | `1` | 限制实例数（限流器单实例才能工作） |
| `ENABLE_FRONTEND` | `true` | 启用内置 Web 界面 |
| `RATE_LIMIT` | `500` | 每 IP 每周期请求数 |
| `RATE_PERIOD_HOURS` | `3` | 限流周期（小时） |

> `SERVER_HOST` 和 `SERVER_PORT` **不要手动设置**——`FUNCTIONS_CUSTOMHANDLER_PORT` 由 Host 自动注入，代码会自动检测并使用。

### 3. 绑定自定义域名 `hubproxy.khbit.cn`

#### 步骤一：添加 DNS CNAME 记录

在你的域名 DNS 管理面板中添加：

| 类型 | 主机记录 | 记录值 | TTL |
|------|---------|--------|-----|
| `CNAME` | `hubproxy` | `<你的函数App>.chinacloudsites.cn`（或 `<你的函数App>.azurewebsites.net`） | 600 |

> 具体 CNAME 目标值在 Azure Portal → Function App → **自定义域 → 添加自定义域** 时会提示。

#### 步骤二：在 Azure 门户绑定域名

1. 进入 Function App → **设置 → 自定义域**
2. 点击 **添加自定义域**
3. 输入 `hubproxy.khbit.cn`
4. 选择 **验证方式**：
   - **CNAME 验证**：已添加 CNAME 记录则自动通过
   - **HTML 验证**：按提示在域名根目录放置验证文件
5. 验证通过后，点击 **添加**
6. 如需 HTTPS，添加 **TLS/SSL 设置** → **添加 TLS 绑定**，选择 **Free Managed Certificate** 或上传自有证书

#### 步骤三：验证

```bash
# 验证域名解析
nslookup hubproxy.khbit.cn

# 验证服务就绪
curl https://hubproxy.khbit.cn/ready

# 测试 Docker 镜像加速
docker pull hubproxy.khbit.cn/library/nginx

# 测试 GitHub 加速
curl -I "https://hubproxy.khbit.cn/https://github.com/sky22333/hubproxy/releases/latest"
```

## 二、CI 自动部署

### 首次配置

在 GitHub 仓库中设置：

```
Settings → Secrets and variables → Actions

Secrets（已配置）:
  ✅ AZURE_FUNCTIONAPP_PUBLISH_PROFILE  — 从 Azure Portal 下载的发布配置文件

Variables（需新建）:
  ➕ AZURE_FUNCTIONAPP_NAME = 你的 Function App 名称
```

### 触发部署

**自动触发**：push 到 `main` 分支且修改了 `src/`、`web/`、`azure/` 路径下的文件时自动部署。

**手动触发**：进入 Actions → Deploy to Azure Functions → Run workflow，可指定版本号。

### 部署流程

```
npm ci + npm run build (前端)
  → CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build (Go 二进制)
    → 组装 deploy/ (host.json + proxy/ + hubproxy + config.toml)
      → zip 打包
        → ① 上传 Actions Artifact（始终执行）
        → ② 可选创建 GitHub Release
        → ③ Azure/functions-action@v1 自动部署（失败不影响 ①②）
```

### 手动触发选项

Actions → Deploy to Azure Functions → **Run workflow** 时可选：

| 输入项 | 说明 |
|--------|------|
| `version` | 版本号，默认 `latest`（自动生成 `日期-SHA前7位`） |
| `create_release` | 勾选后创建 GitHub Release 并附带部署包 |
| `deploy` | 取消勾选则跳过自动部署（只构建+传 artifact） |

### 自动部署失败时的处理

workflow 会**先上传 Actions Artifact 再尝试自动部署**，所以即使 `Azure/functions-action` 失败，部署包也已安全保存在 Actions 页面：

1. 进入 Actions → 失败的 run → 底部 **Artifacts** 区域
2. 下载 `hubproxy-azure-<版本>.zip`
3. 按下方「手动上传」步骤部署

## 三、手动上传部署包

当自动部署失败或你想完全掌控部署时，用 Azure Portal 直接上传 zip：

### 方式一：部署中心（推荐）

1. Azure Portal → 你的 Function App → **部署中心**
2. 选择 **外部 Git / 手动部署** 或 **上传文件**
3. 上传 `deploy-package.zip`（从 Actions Artifact 或 GitHub Release 下载）

### 方式二：SCM Kudu 控制台

1. 打开 `https://<你的函数App>.scm.chinacloudsites.cn/`（中国区）或 `https://<你的函数App>.scm.azurewebsites.net/`（国际版）
2. 登录后进入 **Debug console → CMD**
3. 将 zip 上传到 `/home/site/wwwroot`，然后执行解压：
   ```bash
   cd /home/site/wwwroot
   unzip -o deploy-package.zip
   ```
4. 重启 Function App

### 方式三：Azure CLI（可选）

```bash
az functionapp deployment source config-zip \
  --resource-group <资源组> \
  --name <函数App名> \
  --src deploy-package.zip
```

### 手动上传后的验证

```bash
curl https://<你的函数App>.azurewebsites.net/ready
# 或绑定了域名后
curl https://hubproxy.khbit.cn/ready
```

> **注意**：手动上传 zip 时，zip 的**根目录**必须直接包含 `host.json` 和 `proxy/` 文件夹（CI 打包的 `deploy-package.zip` 已满足此要求）。

## 四、本地构建（可选）

如果你需要在本地手动构建部署包：

```powershell
# PowerShell
./build-azure.ps1                              # 默认 amd64
./build-azure.ps1 -Arch arm64                  # ARM64
./build-azure.ps1 -Version v1.2.3 -SkipFrontend  # 指定版本，跳过前端编译
```

输出：`build/hubproxy-azure-amd64.zip`，可直接在 Azure Portal → Function App → 部署中心上传。

## 五、注意事项

### 超时限制

| 计划 | HTTP 请求超时 | 说明 |
|------|-------------|------|
| **Consumption** | 5 分钟（最大 10 分钟） | ❌ 不适合：Docker 镜像下载 / GitHub 大文件会中断 |
| **Premium (EP1)** | 无限制 | ✅ 推荐 |
| **Dedicated** | 无限制 | ✅ 可用 |

### 有状态功能

限流器和 Token 缓存是内存级的。多实例部署时：
- 每个实例有独立的限流计数（不会叠加）
- Token 缓存不共享
- 建议设置 `WEBSITE_MAX_DYNAMIC_APPLICATION_SCALE_OUT=1` 保持单实例

### 不支持的功能

- **H2C (HTTP/2 Cleartext)**：Azure 仅支持 HTTP/1.1 转发，代码已自动禁用
- **WebSocket 长连接**：当前代码未使用，无影响
