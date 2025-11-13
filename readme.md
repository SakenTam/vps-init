## 💡 如何使用

### 步骤一：将脚本下载到您的 VPS

如果您的新系统已安装 `curl` 或 `wget`：

```bash
curl -L -o init.sh https://raw.githubusercontent.com/SakenTam/vps-init/refs/heads/main/init.sh
```

### 步骤二：运行脚本

这是最关键的步骤，请严格遵守：

添加执行权限:

```bash
chmod +x init.sh
```

切换到 Root 用户:

```bash
sudo -i
```

使用 bash 运行脚本 (请勿使用 sh):

```bash
bash ./init.sh
```
