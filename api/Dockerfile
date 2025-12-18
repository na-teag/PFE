FROM python:3.11-slim

# Installer les dépendances système pour compiler certaines libs Python
RUN apt-get update && apt-get install -y \
    build-essential \
    python3-dev \
    libffi-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copier requirements et installer les packages
COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

# Copier le code Python
COPY main.py .

# Exposer le port 8000
EXPOSE 8000

# Démarrer l'API
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
