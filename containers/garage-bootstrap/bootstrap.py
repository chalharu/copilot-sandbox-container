#!/usr/bin/env python3
import hashlib
import hmac
import html
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def die(message: str) -> None:
    print(f"garage-bootstrap: {message}", file=sys.stderr, flush=True)
    raise SystemExit(64)


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        die(f"{name} is required")
    assert value is not None
    return value


def read_secret(path: str) -> str:
    if not os.path.isfile(path):
        die(f"secret file not found: {path}")
    with open(path, encoding="utf-8") as handle:
        value = handle.read().strip()
    if not value:
        die(f"secret file must not be empty: {path}")
    return value


def request(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    expected: tuple[int, ...] | None = (200,),
) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            status = response.getcode()
            payload = response.read()
    except urllib.error.HTTPError as err:
        status = err.code
        payload = err.read()
    except urllib.error.URLError as err:
        raise RuntimeError(f"{method} {url} failed: {err}") from err

    if expected is not None and status not in expected:
        text = payload.decode("utf-8", "replace")
        raise RuntimeError(f"{method} {url} failed with HTTP {status}: {text}")
    return status, payload


def admin_json(
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
    expected: tuple[int, ...] = (200, 201, 204),
) -> dict[str, object] | None:
    headers = {"Authorization": f"Bearer {admin_token}"}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode("utf-8")
    _, response_body = request(method, f"{admin_url}{path}", headers=headers, body=body, expected=expected)
    if not response_body:
        return None
    return json.loads(response_body.decode("utf-8"))


def wait_for_admin() -> None:
    deadline = time.time() + wait_timeout_seconds
    while time.time() < deadline:
        try:
            admin_json("GET", "/v2/GetClusterStatus")
            return
        except RuntimeError:
            time.sleep(2)
    die("Garage admin API did not become ready")


def wait_for_s3() -> None:
    deadline = time.time() + wait_timeout_seconds
    while time.time() < deadline:
        try:
            request("GET", s3_endpoint, expected=(200, 301, 302, 307, 403))
            return
        except RuntimeError:
            time.sleep(2)
    die("Garage S3 API did not become ready")


def upsert_layout() -> None:
    status_json = admin_json("GET", "/v2/GetClusterStatus")
    node_id = ((status_json or {}).get("nodes") or [{}])[0].get("id", "")
    if not node_id:
        die("Garage did not report any cluster node")

    current_role: dict[str, object] = {}
    for node in (status_json or {}).get("nodes", []):
        if node.get("id") == node_id:
            current_role = node.get("role") or {}
            break

    normalized_current = {
        "zone": current_role.get("zone"),
        "capacity": current_role.get("capacity"),
        "tags": sorted(current_role.get("tags") or []),
    }
    normalized_desired = {
        "zone": layout_zone,
        "capacity": layout_capacity_bytes,
        "tags": sorted(layout_tags),
    }
    if normalized_current == normalized_desired:
        return

    layout_json = admin_json(
        "POST",
        "/v2/UpdateClusterLayout",
        {
            "roles": [
                {
                    "id": node_id,
                    "zone": layout_zone,
                    "capacity": layout_capacity_bytes,
                    "tags": layout_tags,
                }
            ]
        },
        expected=(200, 201),
    )
    admin_json(
        "POST",
        "/v2/ApplyClusterLayout",
        {"version": int((layout_json or {})["version"]) + 1},
        expected=(200, 204),
    )


def upsert_key() -> None:
    payload = {
        "accessKeyId": aws_access_key_id,
        "secretAccessKey": aws_secret_access_key,
        "name": s3_key_name,
    }
    try:
        key_json = admin_json("POST", "/v2/ImportKey", payload, expected=(200, 201))
    except RuntimeError:
        quoted_key_id = urllib.parse.quote(aws_access_key_id, safe="")
        key_json = admin_json("GET", f"/v2/GetKeyInfo?id={quoted_key_id}&showSecretKey=true")
    actual_secret = (key_json or {}).get("secretAccessKey", "")
    if actual_secret != aws_secret_access_key:
        die(f"Garage key {aws_access_key_id} already exists with a different secret")


def upsert_bucket() -> None:
    try:
        bucket_json = admin_json(
            "POST",
            "/v2/CreateBucket",
            {"globalAlias": s3_bucket},
            expected=(200, 201),
        )
    except RuntimeError:
        quoted_bucket = urllib.parse.quote(s3_bucket, safe="")
        bucket_json = admin_json("GET", f"/v2/GetBucketInfo?globalAlias={quoted_bucket}")

    bucket_id = (bucket_json or {}).get("id", "")
    if not bucket_id:
        die(f"Garage bucket {s3_bucket} did not report an id")

    quoted_bucket_id = urllib.parse.quote(bucket_id, safe="")
    admin_json(
        "POST",
        f"/v2/UpdateBucket?id={quoted_bucket_id}",
        {"quotas": {"maxSize": cache_quota_bytes, "maxObjects": None}},
        expected=(200, 204),
    )
    admin_json(
        "POST",
        "/v2/AllowBucketKey",
        {
            "bucketId": bucket_id,
            "accessKeyId": aws_access_key_id,
            "permissions": {"owner": True, "read": True, "write": True},
        },
        expected=(200, 204),
    )


def get_signature_key(secret_key: str, date_stamp: str, region_name: str, service_name: str) -> bytes:
    date_key = hmac.new(("AWS4" + secret_key).encode("utf-8"), date_stamp.encode("utf-8"), hashlib.sha256).digest()
    region_key = hmac.new(date_key, region_name.encode("utf-8"), hashlib.sha256).digest()
    service_key = hmac.new(region_key, service_name.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(service_key, b"aws4_request", hashlib.sha256).digest()


def apply_lifecycle() -> None:
    prefix_xml = html.escape(s3_key_prefix)
    lifecycle_xml = f"""<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule>
    <ID>sccache-expiry</ID>
    <Status>Enabled</Status>
    <Filter>
      <Prefix>{prefix_xml}</Prefix>
    </Filter>
    <Expiration>
      <Days>{cache_expiration_days}</Days>
    </Expiration>
    <AbortIncompleteMultipartUpload>
      <DaysAfterInitiation>{abort_multipart_days}</DaysAfterInitiation>
    </AbortIncompleteMultipartUpload>
  </Rule>
</LifecycleConfiguration>"""
    lifecycle_body = lifecycle_xml.encode("utf-8")
    parsed_endpoint = urllib.parse.urlparse(s3_endpoint)
    if not parsed_endpoint.scheme or not parsed_endpoint.netloc:
        die(f"invalid GARAGE_S3_ENDPOINT: {s3_endpoint}")

    canonical_uri = f"/{s3_bucket}"
    canonical_query = "lifecycle="
    payload_hash = hashlib.sha256(lifecycle_body).hexdigest()
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    canonical_headers = {
        "content-type": "application/xml",
        "host": parsed_endpoint.netloc,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    canonical_headers_block = "".join(f"{key}:{canonical_headers[key]}\n" for key in sorted(canonical_headers))
    signed_headers = ";".join(sorted(canonical_headers))
    canonical_request = "\n".join(
        [
            "PUT",
            canonical_uri,
            canonical_query,
            canonical_headers_block,
            signed_headers,
            payload_hash,
        ]
    )
    credential_scope = f"{date_stamp}/{s3_region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        get_signature_key(aws_secret_access_key, date_stamp, s3_region, "s3"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={aws_access_key_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )
    request(
        "PUT",
        f"{s3_endpoint.rstrip('/')}{canonical_uri}?lifecycle=",
        headers={
            "Authorization": authorization,
            "Content-Type": "application/xml",
            "Host": parsed_endpoint.netloc,
            "X-Amz-Content-Sha256": payload_hash,
            "X-Amz-Date": amz_date,
        },
        body=lifecycle_body,
        expected=(200,),
    )


admin_url = env("GARAGE_ADMIN_URL", required=True)
s3_endpoint = env("GARAGE_S3_ENDPOINT", required=True)
s3_region = env("GARAGE_S3_REGION", "garage")
s3_bucket = env("GARAGE_S3_BUCKET", required=True)
s3_key_name = env("GARAGE_S3_KEY_NAME", s3_bucket)
s3_key_prefix = env("GARAGE_S3_KEY_PREFIX", "sccache/")
layout_zone = env("GARAGE_LAYOUT_ZONE", "dc1")
layout_tags = [tag.strip() for tag in env("GARAGE_LAYOUT_TAGS", "control-plane,sccache").split(",") if tag.strip()]
layout_capacity_bytes = int(env("GARAGE_LAYOUT_CAPACITY_BYTES", "5368709120"))
cache_quota_bytes = int(env("GARAGE_CACHE_QUOTA_BYTES", "4294967296"))
cache_expiration_days = int(env("GARAGE_CACHE_EXPIRATION_DAYS", "30"))
abort_multipart_days = int(env("GARAGE_ABORT_MULTIPART_DAYS", "1"))
wait_timeout_seconds = int(env("GARAGE_WAIT_TIMEOUT_SECONDS", "120"))
admin_token = read_secret(env("GARAGE_ADMIN_TOKEN_FILE", required=True))
aws_access_key_id = read_secret(env("AWS_ACCESS_KEY_ID_FILE", required=True))
aws_secret_access_key = read_secret(env("AWS_SECRET_ACCESS_KEY_FILE", required=True))

wait_for_admin()
upsert_layout()
upsert_key()
upsert_bucket()
wait_for_s3()
apply_lifecycle()
print("garage-bootstrap: bootstrap complete", flush=True)
