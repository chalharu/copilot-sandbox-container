#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'garage-entrypoint: %s\n' "$*" >&2
  exit 64
}

require_integer() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an integer: ${value}"
}

read_secret() {
  local path="$1"
  local name="$2"
  local value

  [[ -f "${path}" ]] || die "${name} file not found: ${path}"
  value="$(tr -d '\r\n' < "${path}")"
  [[ -n "${value}" ]] || die "${name} file must not be empty: ${path}"
  printf '%s' "${value}"
}

uri_encode() {
  jq -rn --arg value "$1" '$value|@uri'
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/garage-bootstrap.XXXXXX")"
server_pid=""

cleanup() {
  rm -rf "${tmpdir}" >/dev/null 2>&1 || true
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

garage_data_root="${GARAGE_DATA_ROOT:-/var/lib/garage}"
garage_metadata_dir="${GARAGE_METADATA_DIR:-${garage_data_root}/meta}"
garage_storage_dir="${GARAGE_STORAGE_DIR:-${garage_data_root}/data}"
garage_config_path="${GARAGE_CONFIG_PATH:-${garage_data_root}/garage.toml}"
garage_rpc_bind_addr="${GARAGE_RPC_BIND_ADDR:-0.0.0.0:3901}"
garage_rpc_public_addr="${GARAGE_RPC_PUBLIC_ADDR:-}"
garage_s3_bind_addr="${GARAGE_S3_BIND_ADDR:-0.0.0.0:3900}"
garage_admin_bind_addr="${GARAGE_ADMIN_BIND_ADDR:-127.0.0.1:3903}"
garage_admin_url="${GARAGE_ADMIN_URL:-http://127.0.0.1:3903}"
garage_s3_endpoint="${GARAGE_S3_ENDPOINT:-http://127.0.0.1:3900}"
garage_s3_region="${GARAGE_S3_REGION:-garage}"
garage_s3_bucket="${GARAGE_S3_BUCKET:-control-plane-sccache}"
garage_s3_key_name="${GARAGE_S3_KEY_NAME:-${garage_s3_bucket}}"
garage_s3_key_prefix="${GARAGE_S3_KEY_PREFIX:-sccache/}"
garage_layout_zone="${GARAGE_LAYOUT_ZONE:-dc1}"
garage_layout_tags_csv="${GARAGE_LAYOUT_TAGS:-control-plane,sccache}"
garage_layout_capacity_bytes="${GARAGE_LAYOUT_CAPACITY_BYTES:-5368709120}"
garage_cache_quota_bytes="${GARAGE_CACHE_QUOTA_BYTES:-4294967296}"
garage_cache_expiration_days="${GARAGE_CACHE_EXPIRATION_DAYS:-30}"
garage_abort_multipart_days="${GARAGE_ABORT_MULTIPART_DAYS:-1}"
garage_replication_factor="${GARAGE_REPLICATION_FACTOR:-1}"
garage_db_engine="${GARAGE_DB_ENGINE:-sqlite}"
garage_rpc_secret_file="${GARAGE_RPC_SECRET_FILE:-}"
garage_admin_token_file="${GARAGE_ADMIN_TOKEN_FILE:-}"
aws_access_key_id_file="${AWS_ACCESS_KEY_ID_FILE:-}"
aws_secret_access_key_file="${AWS_SECRET_ACCESS_KEY_FILE:-}"

[[ -n "${garage_rpc_public_addr}" ]] || die "GARAGE_RPC_PUBLIC_ADDR is required"
[[ -n "${garage_rpc_secret_file}" ]] || die "GARAGE_RPC_SECRET_FILE is required"
[[ -n "${garage_admin_token_file}" ]] || die "GARAGE_ADMIN_TOKEN_FILE is required"
[[ -n "${aws_access_key_id_file}" ]] || die "AWS_ACCESS_KEY_ID_FILE is required"
[[ -n "${aws_secret_access_key_file}" ]] || die "AWS_SECRET_ACCESS_KEY_FILE is required"

require_integer "GARAGE_LAYOUT_CAPACITY_BYTES" "${garage_layout_capacity_bytes}"
require_integer "GARAGE_CACHE_QUOTA_BYTES" "${garage_cache_quota_bytes}"
require_integer "GARAGE_CACHE_EXPIRATION_DAYS" "${garage_cache_expiration_days}"
require_integer "GARAGE_ABORT_MULTIPART_DAYS" "${garage_abort_multipart_days}"
require_integer "GARAGE_REPLICATION_FACTOR" "${garage_replication_factor}"

rpc_secret="$(read_secret "${garage_rpc_secret_file}" GARAGE_RPC_SECRET)"
admin_token="$(read_secret "${garage_admin_token_file}" GARAGE_ADMIN_TOKEN)"
aws_access_key_id="$(read_secret "${aws_access_key_id_file}" AWS_ACCESS_KEY_ID)"
aws_secret_access_key="$(read_secret "${aws_secret_access_key_file}" AWS_SECRET_ACCESS_KEY)"
garage_layout_tags_json="$(jq -Rn --arg raw "${garage_layout_tags_csv}" '$raw | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

mkdir -p "${garage_metadata_dir}" "${garage_storage_dir}"

cat > "${garage_config_path}" <<EOF
metadata_dir = "${garage_metadata_dir}"
data_dir = "${garage_storage_dir}"
db_engine = "${garage_db_engine}"
replication_factor = ${garage_replication_factor}

rpc_bind_addr = "${garage_rpc_bind_addr}"
rpc_public_addr = "${garage_rpc_public_addr}"
rpc_secret = "${rpc_secret}"

[s3_api]
s3_region = "${garage_s3_region}"
api_bind_addr = "${garage_s3_bind_addr}"

[admin]
api_bind_addr = "${garage_admin_bind_addr}"
admin_token = "${admin_token}"
EOF

api_status=""
api_body=""

api_request() {
  local method="$1"
  local path="$2"
  local body="${3-}"
  local response_path
  local curl_args

  response_path="$(mktemp "${tmpdir}/admin-response.XXXXXX")"
  curl_args=(
    -sS
    -o "${response_path}"
    -w '%{http_code}'
    -X "${method}"
    -H "Authorization: Bearer ${admin_token}"
  )
  if [[ -n "${body}" ]]; then
    curl_args+=(-H 'Content-Type: application/json' --data "${body}")
  fi

  api_status="$(curl "${curl_args[@]}" "${garage_admin_url}${path}")"
  api_body="$(cat "${response_path}")"
  rm -f "${response_path}"
}

api_json() {
  api_request "$@"
  if [[ ! "${api_status}" =~ ^2 ]]; then
    printf 'garage-entrypoint: %s %s failed with HTTP %s\n' "$1" "$2" "${api_status}" >&2
    printf '%s\n' "${api_body}" >&2
    return 1
  fi
  printf '%s' "${api_body}"
}

wait_for_admin() {
  for _ in $(seq 1 60); do
    if api_json GET /v2/GetClusterStatus >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  die "Garage admin API did not become ready"
}

wait_for_s3() {
  for _ in $(seq 1 60); do
    if curl -sS -o /dev/null "${garage_s3_endpoint}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  die "Garage S3 API did not become ready"
}

upsert_layout() {
  local status_json
  local node_id
  local existing_role
  local desired_role
  local update_payload
  local layout_json
  local apply_payload

  status_json="$(api_json GET /v2/GetClusterStatus)"
  node_id="$(jq -r '.nodes[0].id // empty' <<<"${status_json}")"
  [[ -n "${node_id}" ]] || die "Garage did not report any cluster node"

  existing_role="$(jq -c --arg id "${node_id}" '(.nodes[] | select(.id == $id) | .role) // {} | {zone, capacity, tags}' <<<"${status_json}")"
  desired_role="$(jq -cn --arg zone "${garage_layout_zone}" --argjson capacity "${garage_layout_capacity_bytes}" --argjson tags "${garage_layout_tags_json}" '{zone:$zone, capacity:$capacity, tags:$tags}')"

  if [[ "${existing_role}" == "${desired_role}" ]]; then
    return 0
  fi

  update_payload="$(jq -cn --arg id "${node_id}" --arg zone "${garage_layout_zone}" --argjson capacity "${garage_layout_capacity_bytes}" --argjson tags "${garage_layout_tags_json}" '{roles:[{id:$id, zone:$zone, capacity:$capacity, tags:$tags}]}')"
  layout_json="$(api_json POST /v2/UpdateClusterLayout "${update_payload}")"
  apply_payload="$(jq -cn --argjson version "$(jq '.version + 1' <<<"${layout_json}")" '{version:$version}')"
  api_json POST /v2/ApplyClusterLayout "${apply_payload}" >/dev/null
}

upsert_key() {
  local import_payload
  local import_status
  local import_body
  local key_json
  local actual_secret

  import_payload="$(jq -cn --arg id "${aws_access_key_id}" --arg secret "${aws_secret_access_key}" --arg name "${garage_s3_key_name}" '{accessKeyId:$id, secretAccessKey:$secret, name:$name}')"
  api_request POST /v2/ImportKey "${import_payload}"
  import_status="${api_status}"
  import_body="${api_body}"
  if [[ ! "${api_status}" =~ ^2 ]]; then
    key_json="$(api_json GET "/v2/GetKeyInfo?id=$(uri_encode "${aws_access_key_id}")&showSecretKey=true")" || {
      printf 'garage-entrypoint: ImportKey failed with HTTP %s\n' "${import_status}" >&2
      printf '%s\n' "${import_body}" >&2
      return 1
    }
  else
    key_json="${api_body}"
  fi

  actual_secret="$(jq -r '.secretAccessKey // empty' <<<"${key_json}")"
  [[ "${actual_secret}" == "${aws_secret_access_key}" ]] || die "Garage key ${aws_access_key_id} already exists with a different secret"
}

upsert_bucket() {
  local create_payload
  local create_status
  local create_body
  local bucket_json
  local bucket_id
  local quota_payload
  local allow_payload

  create_payload="$(jq -cn --arg alias "${garage_s3_bucket}" '{globalAlias:$alias}')"
  api_request POST /v2/CreateBucket "${create_payload}"
  create_status="${api_status}"
  create_body="${api_body}"
  if [[ ! "${api_status}" =~ ^2 ]]; then
    bucket_json="$(api_json GET "/v2/GetBucketInfo?globalAlias=$(uri_encode "${garage_s3_bucket}")")" || {
      printf 'garage-entrypoint: CreateBucket failed with HTTP %s\n' "${create_status}" >&2
      printf '%s\n' "${create_body}" >&2
      return 1
    }
  else
    bucket_json="${api_body}"
  fi

  bucket_id="$(jq -r '.id // empty' <<<"${bucket_json}")"
  [[ -n "${bucket_id}" ]] || die "Garage bucket ${garage_s3_bucket} did not report an id"

  quota_payload="$(jq -cn --argjson max_size "${garage_cache_quota_bytes}" '{quotas:{maxSize:$max_size, maxObjects:null}}')"
  api_json POST "/v2/UpdateBucket?id=$(uri_encode "${bucket_id}")" "${quota_payload}" >/dev/null

  allow_payload="$(jq -cn --arg bucket_id "${bucket_id}" --arg access_key_id "${aws_access_key_id}" '{bucketId:$bucket_id, accessKeyId:$access_key_id, permissions:{owner:true, read:true, write:true}}')"
  api_json POST /v2/AllowBucketKey "${allow_payload}" >/dev/null
}

apply_lifecycle() {
  local lifecycle_path

  lifecycle_path="${tmpdir}/sccache-lifecycle.json"
  jq -cn \
    --arg prefix "${garage_s3_key_prefix}" \
    --argjson expiration_days "${garage_cache_expiration_days}" \
    --argjson abort_days "${garage_abort_multipart_days}" \
    '{
      Rules: [
        {
          ID: "expire-sccache-objects",
          Status: "Enabled",
          Filter: { Prefix: $prefix },
          Expiration: { Days: $expiration_days },
          AbortIncompleteMultipartUpload: { DaysAfterInitiation: $abort_days }
        }
      ]
    }' > "${lifecycle_path}"

  export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
  export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
  export AWS_DEFAULT_REGION="${garage_s3_region}"

  for _ in $(seq 1 30); do
    if aws s3api put-bucket-lifecycle-configuration \
      --endpoint-url "${garage_s3_endpoint}" \
      --bucket "${garage_s3_bucket}" \
      --lifecycle-configuration "file://${lifecycle_path}" >/dev/null; then
      return 0
    fi
    sleep 2
  done

  die "failed to apply Garage bucket lifecycle configuration"
}

garage -c "${garage_config_path}" server &
server_pid="$!"

wait_for_admin
wait_for_s3
upsert_layout
upsert_key
upsert_bucket
apply_lifecycle

wait "${server_pid}"
