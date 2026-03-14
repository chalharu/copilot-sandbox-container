FROM dhi.io/python:3-alpine3.23-dev AS builder

# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv "${VIRTUAL_ENV}" \
    && python -m pip install --no-cache-dir "yamllint==${YAMLLINT_VERSION}"

FROM dhi.io/python:3-alpine3.23

ENV VIRTUAL_ENV=/opt/yamllint
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

COPY --from=builder "${VIRTUAL_ENV}" "${VIRTUAL_ENV}"

WORKDIR /workspace
ENTRYPOINT ["yamllint"]
