FROM python:3.12-slim
RUN useradd -m -u 1000 sandbox
WORKDIR /app
COPY app.py /app/app.py
USER sandbox
EXPOSE 8080
CMD ["python", "/app/app.py"]
