FROM python:3.12-slim

# Install system dependencies for Chromium
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    xdg-utils \
    libu2f-udev \
    libvulkan1 \
    && rm -rf /var/lib/apt/lists/*

# Install uv for fast Python package management
RUN pip install --no-cache-dir uv

# Create virtual environment
RUN uv venv /app/.venv --python 3.12

# Install browser-use and its dependencies into the venv
RUN . /app/.venv/bin/activate && \
    uv pip install browser-use langchain-anthropic langchain-google-genai langchain-openai

# Install browser (Playwright chromium) into the venv
RUN . /app/.venv/bin/activate && \
    playwright install chromium && \
    playwright install-deps chromium

# Working directory
WORKDIR /app

# Copy entrypoint
COPY entrypoint.py /app/entrypoint.py

# Task mount point
VOLUME /task

# Entrypoint
ENTRYPOINT ["/app/.venv/bin/python", "/app/entrypoint.py"]
