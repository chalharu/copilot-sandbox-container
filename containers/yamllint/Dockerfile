FROM dhi.io/python:3-alpine3.23-dev@sha256:b2980709a42daa6a7c3f02b835bd6d358d5f2970ffce38567f20f6a6f6d6a1de AS builder

# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv "${VIRTUAL_ENV}" \
    && python -m pip install --no-cache-dir "yamllint==${YAMLLINT_VERSION}"

FROM dhi.io/python:3-alpine3.23@sha256:44f462f0f4f9f1a33de3306ca1b01505d4a080684362108c70be0a3e2ac3f242

ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --from=builder "${VIRTUAL_ENV}" "${VIRTUAL_ENV}"

WORKDIR /workspace
ENTRYPOINT ["yamllint"]
