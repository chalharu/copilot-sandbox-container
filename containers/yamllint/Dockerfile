FROM dhi.io/python:3-alpine3.23-dev@sha256:ce27f69c9d49f99fa0906d4180606162cc16c2c1c6dea8700169164b1a641a5c AS builder

# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv "${VIRTUAL_ENV}" \
    && python -m pip install --no-cache-dir "yamllint==${YAMLLINT_VERSION}"

FROM dhi.io/python:3-alpine3.23@sha256:85af4b4082125ed0c965c55338e0b8dd85921e86fb0d1163d868808f85d6cfee

ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --from=builder "${VIRTUAL_ENV}" "${VIRTUAL_ENV}"

WORKDIR /workspace
ENTRYPOINT ["yamllint"]
