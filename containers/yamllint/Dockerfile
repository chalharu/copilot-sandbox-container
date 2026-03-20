FROM dhi.io/python:3-alpine3.23-dev@sha256:ce27f69c9d49f99fa0906d4180606162cc16c2c1c6dea8700169164b1a641a5c AS builder

# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv "${VIRTUAL_ENV}" \
    && python -m pip install --no-cache-dir "yamllint==${YAMLLINT_VERSION}"

FROM dhi.io/python:3-alpine3.23@sha256:8dbcce9cf42e0fc567abfefdbfde88328d25f43986651802984b4235cd6831dd

ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --from=builder "${VIRTUAL_ENV}" "${VIRTUAL_ENV}"

WORKDIR /workspace
ENTRYPOINT ["yamllint"]
