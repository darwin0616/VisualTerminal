# 測試用 SSH 伺服器

只供開發測試，只綁定在本機 127.0.0.1:2222。

    docker build -t vt-sshd testserver
    docker run -d --name vt-sshd -p 127.0.0.1:2222:22 -v /var/run/docker.sock:/var/run/docker.sock vt-sshd

帳號 `tester`、密碼 `tester`。容器內的 `docker` 指令會看到 Mac 上的容器。
