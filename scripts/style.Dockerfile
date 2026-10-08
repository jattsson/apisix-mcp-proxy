FROM python:3.14.3-slim@sha256:5e59aae31ff0e87511226be8e2b94d78c58f05216efda3b07dbbed938ec8583b
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip lua5.1 liblua5.1-0-dev luarocks gcc libc6-dev \
    && luarocks install luacheck 1.2.0 \
    && rm -rf /var/lib/apt/lists/*
ARG STYLUA_VERSION=2.5.2
RUN curl -fsSL "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-linux-x86_64.zip" \
    -o /tmp/stylua.zip \
    && unzip /tmp/stylua.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/stylua \
    && rm /tmp/stylua.zip
WORKDIR /work
