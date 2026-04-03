# Telemon Dockerfile
# Builds a containerized version of Telemon for monitoring from within Docker

FROM alpine:3.19

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    coreutils \
    procps \
    iputils \
    docker-cli \
    tzdata \
    envsubst

# Create telemon directory
WORKDIR /opt/telemon

# Copy telemon files
COPY telemon.sh .
COPY install.sh .
COPY uninstall.sh .
COPY update.sh .
COPY telemon-admin.sh .
COPY telemon-logrotate.conf .
COPY .env.example .
COPY README.md .
COPY LICENSE .

# Make scripts executable
RUN chmod +x *.sh

# Create directories
RUN mkdir -p /var/log/telemon /var/lib/telemon

# Health check - verify telemon can run (dry run)
HEALTHCHECK --interval=5m --timeout=3s \
    CMD bash -n /opt/telemon/telemon.sh || exit 1

# Default environment
ENV TELEGRAM_BOT_TOKEN=""
ENV TELEGRAM_CHAT_ID=""
ENV STATE_FILE="/var/lib/telemon/state"
ENV LOG_FILE="/var/log/telemon/telemon.log"
ENV SCRIPT_DIR="/opt/telemon"

# Run telemon (requires .env to be mounted)
ENTRYPOINT ["bash", "./telemon.sh"]
