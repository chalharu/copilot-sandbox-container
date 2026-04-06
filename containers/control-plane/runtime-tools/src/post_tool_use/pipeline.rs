use std::collections::HashMap;
use std::path::{Path, PathBuf};

use super::config::Config;
use super::git;

pub struct ClassifiedFiles {
    pub matched_files: Vec<PathBuf>,
    pub files_by_pipeline: HashMap<String, Vec<String>>,
}

pub fn current_relevant_files(config: &Config, repo_root: &Path) -> Result<ClassifiedFiles, String> {
    let dirty_files = git::list_dirty_files(repo_root)?;
    Ok(classify_files_by_pipeline(config, repo_root, &dirty_files))
}

pub fn classify_files_by_pipeline(
    config: &Config,
    repo_root: &Path,
    files: &[PathBuf],
) -> ClassifiedFiles {
    let mut files_by_pipeline = pipeline_buckets(config);
    let mut matched_files = Vec::new();

    for file_path in files {
        if let Some((pipeline_id, relative_path)) = classify_file(config, repo_root, file_path) {
            files_by_pipeline
                .entry(pipeline_id)
                .or_default()
                .push(relative_path);
            matched_files.push(file_path.clone());
        }
    }

    ClassifiedFiles {
        matched_files,
        files_by_pipeline,
    }
}

fn pipeline_buckets(config: &Config) -> HashMap<String, Vec<String>> {
    config
        .pipelines
        .iter()
        .map(|pipeline| (pipeline.id.clone(), Vec::new()))
        .collect()
}

fn classify_file(config: &Config, repo_root: &Path, file_path: &Path) -> Option<(String, String)> {
    let relative_path = git::to_relative_repo_path(repo_root, file_path);
    for pipeline in &config.pipelines {
        if pipeline.matcher.is_match(&relative_path) {
            return Some((pipeline.id.clone(), relative_path));
        }
    }
    None
}
