FROM python:3.12-slim-bookworm
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates unixodbc unixodbc-dev && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main' > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 && \
    rm -rf /var/lib/apt/lists/*
RUN python -m pip install --no-cache-dir 'dbt-sqlserver[pyodbc]>=1.11,<1.13'
WORKDIR /workspace
ENTRYPOINT ["dbt"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*