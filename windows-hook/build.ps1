# Rebuilds the proxy version.dll and copies it to windows-hook\version.dll,
# the committed binary the plugin build embeds (esbuild can't compile Rust).
# Run this whenever anything under src\ changes, then rebuild the plugin.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$env:RUSTFLAGS = "--remap-path-prefix=$env:USERPROFILE=~"
cargo build --release
Copy-Item .\target\release\version.dll .\version.dll -Force
"version.dll: {0:N0} bytes" -f (Get-Item .\version.dll).Length
