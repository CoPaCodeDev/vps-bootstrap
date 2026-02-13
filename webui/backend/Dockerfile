FROM python:3.12-slim

WORKDIR /app

# User master (UID 1000) für SSH-Verbindungen
RUN groupadd -g 1000 master && useradd -u 1000 -g 1000 -d /home/master -s /bin/bash master

# SSH-Client für Verbindungen zu VPS
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
