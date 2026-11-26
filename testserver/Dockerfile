# 測試用 SSH 伺服器：帳號 tester / 密碼 tester，容器內可執行 docker（透過掛載的 docker.sock 看到 Mac 上的容器）
FROM alpine:3.20
RUN apk add --no-cache openssh docker-cli bash grep sed gawk coreutils \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash tester && echo "tester:tester" | chpasswd \
 && addgroup tester root \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
