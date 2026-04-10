fn main() -> Result<(), Box<dyn std::error::Error>> {
    let protoc = protoc_bin_vendored::protoc_bin_path()?;
    unsafe {
        std::env::set_var("PROTOC", protoc);
    }

    tonic_build::configure()
        .build_client(true)
        .build_server(true)
        .compile_protos(&["proto/control_plane_exec.proto"], &["proto"])?;

    println!("cargo:rerun-if-changed=proto/control_plane_exec.proto");
    Ok(())
}
