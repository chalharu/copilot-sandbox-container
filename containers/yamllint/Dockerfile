FROM dhi.io/python:3-alpine3.23-dev@sha256:c07730faf95dc5189a5357a083403e64124ba1f90acfeef4b05385261b4ac7a0 AS builder

# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv "${VIRTUAL_ENV}" \
    && python -m pip install --no-cache-dir "yamllint==${YAMLLINT_VERSION}"

FROM dhi.io/python:3-alpine3.23@sha256:e6aa0c22d51269a8cdefe8077a96e7f3b9eb7cbf49112557f493389de6a43bed

ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --from=builder "${VIRTUAL_ENV}" "${VIRTUAL_ENV}"

WORKDIR /workspace
ENTRYPOINT ["yamllint"]
