# Use python-slim as the base image
FROM python:3.10-slim AS base

# Set shell to bash with pipefail option
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Consistent environment variables grouped together
ENV DEBIAN_FRONTEND=noninteractive \
    DOCKERMODE=true \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONIOENCODING=UTF-8 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    NAME=Calibre-Web-Automated-Book-Downloader \
    PYTHONPATH=/app \
    # UID/GID will be handled by entrypoint script, but TZ/Locale are still needed
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    APP_ENV=prod

# Set ARG for build-time expansion (FLASK_PORT), ENV for runtime access
ENV FLASK_PORT=8084

# Configure locale, timezone, and perform initial cleanup in a single layer
# User/group creation is removed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # For locale
    locales tzdata \
    # For entrypoint
    dumb-init \
    # For dumb display
    xvfb \
    # For user switching
    sudo \
    # --- Chromium Browser ---
    chromium-driver \
    # For tkinter (pyautogui)
    python3-tk && \
    # Cleanup APT cache *after* all installs in this layer
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Default to UTC timezone but will be overridden by the entrypoint script
    ln -snf /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone && \
    # Configure locale
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    echo "LC_ALL=en_US.UTF-8" >> /etc/environment && \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set working directory
WORKDIR /app

# Install Python dependencies using pip
# Upgrade pip first, then copy requirements and install
# Copying requirements.txt separately leverages build cache
# No --chown needed as it's copied as root
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    # Clean root's pip cache
    rm -rf /root/.cache

# Add this line to grant read/execute permissions to others
RUN chmod -R o+rx /usr/bin/chromium && \
    chmod -R o+rx /usr/bin/chromedriver && \
    chmod -R o+w /usr/local/lib/python3.10/site-packages/seleniumbase/drivers/

# Our custom wanabe curl

RUN echo "#!/bin/sh" > /usr/local/bin/pyrequests && \
    echo 'python -c "import sys, requests; url=sys.argv[1]; r=requests.get(url, timeout=10); print(r.text); sys.exit(0) if r.ok else sys.exit(1)" "$@"' \
      >> /usr/local/bin/pyrequests && \
      chmod +x /usr/local/bin/pyrequests

# Copy application code *after* dependencies are installed
# No --chown needed as it's copied as root, entrypoint will handle permissions
COPY . .

# Final setup: permissions and directories in one layer
# Only creating directories and setting executable bits.
# Ownership will be handled by the entrypoint script.
RUN mkdir -p /var/log/cwa-book-downloader /cwa-book-ingest && \
    chmod +x /app/entrypoint.sh /app/tor.sh 
    # chown is removed


# Expose the application port
EXPOSE ${FLASK_PORT}

# Add healthcheck for container status
# This will run as root initially, but check localhost which should work if the app binds correctly.
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD pyrequests http://localhost:${FLASK_PORT}/request/api/status || exit 1

# Use dumb-init as the entrypoint to handle signals properly
ENTRYPOINT ["/usr/bin/dumb-init", "--"]


FROM base AS cwa-bd

# Default command to run the application entrypoint script
CMD ["/app/entrypoint.sh"]

FROM base AS cwa-bd-tor

ENV ENABLE_TOR=true

# Install Tor and dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # --- Tor ---
    tor iptables && \
    # Cleanup APT cache *after* all installs in this layer
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Tor configuration is handled by entrypoint/script now or permissions set earlier
# RUN chmod +x /app/tor.sh # This is removed as it's done in the base stage setup

# Override the default command to run Tor
CMD ["/app/tor.sh"]
