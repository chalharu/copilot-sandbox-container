use url::Url;

pub(super) fn redact_remote_url(remote_url: &str) -> String {
    redact_standard_remote_url(remote_url)
        .or_else(|| redact_scp_like_remote(remote_url))
        .unwrap_or_else(|| remote_url.to_string())
}

fn redact_standard_remote_url(remote_url: &str) -> Option<String> {
    let mut url = Url::parse(remote_url).ok()?;
    if !url.username().is_empty() {
        let _ = url.set_username("");
    }
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    Some(url.to_string())
}

fn redact_scp_like_remote(remote_url: &str) -> Option<String> {
    if remote_url.contains("://") {
        return None;
    }
    let (userinfo, host_path) = remote_url.split_once('@')?;
    if userinfo.is_empty() || !host_path.contains(':') {
        None
    } else {
        Some(host_path.to_string())
    }
}
