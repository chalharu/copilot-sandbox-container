ARG GARAGE_BOOTSTRAP_VERSION=1.0.0
# renovate: datasource=docker depName=docker.io/library/python versioning=docker
FROM docker.io/library/python:3.14.3-bookworm@sha256:f357fca37376cc10aba3bb909d13bba0108a39670d7b9bc8b4039ac94674e874

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY --chmod=755 bootstrap.py /usr/local/bin/garage-bootstrap

USER 65532:65532

ENTRYPOINT ["python3", "/usr/local/bin/garage-bootstrap"]
