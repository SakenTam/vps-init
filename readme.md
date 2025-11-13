## 💡 如何使用

### 步骤一：将脚本下载到您的 VPS

您有多种方式将此脚本上传到新服务器，这里推荐两种最简单的方法。

**方法 A: 使用 `curl` (推荐)**

如果您的新系统已安装 `curl` 或 `wget`：

```bash
# （请将 URL 替换为您自己的 GitHub 仓库 raw 链接）
curl -L -o init-vps.sh [https://github.com/您的用户名/您的仓库名/raw/main/init-vps.sh](https://github.com/您的用户名/您的仓库名/raw/main/init-vps.sh)
```