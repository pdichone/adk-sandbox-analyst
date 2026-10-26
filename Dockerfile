# Used only by `deploy.sh mcp`. Mirrors the image `adk deploy cloud_run` generates,
# with main.py as the entrypoint so the service also answers on /mcp.
FROM python:3.11-slim
WORKDIR /app
RUN adduser --disabled-password --gecos "" myuser
USER myuser
ENV PATH="/home/myuser/.local/bin:$PATH"
COPY --chown=myuser:myuser requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY --chown=myuser:myuser analyst/ /app/analyst/
COPY --chown=myuser:myuser mcp_server.py main.py /app/
EXPOSE 8080
CMD ["python", "main.py"]
