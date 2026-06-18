FROM python:3.11-slim

WORKDIR /app
COPY app.py /app/app.py

RUN apt-get update \
	&& rm -rf /var/lib/apt/lists/*

EXPOSE 8080

CMD ["python", "/app/app.py"]
