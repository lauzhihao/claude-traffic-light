FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

# 非 root 运行;/data(sqlite)与 /secrets(.p8)由 compose 挂载
RUN useradd -r -u 10001 relay && mkdir -p /data && chown relay /data
USER relay

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
