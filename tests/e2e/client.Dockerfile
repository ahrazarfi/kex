# The user's machine: kex client, an RDP client and a virtual screen to log in and take a screenshot.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client freerdp2-x11 xvfb imagemagick procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY id_test /root/.ssh/id_test
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/id_test
CMD ["sleep", "infinity"]
