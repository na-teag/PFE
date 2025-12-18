FROM python:3.11-slim

# Dépendances système pour Yara et git
RUN apt-get update && apt-get install -y \
    git \
    yara \
    libyara-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

CMD ["python", "main.py"]
