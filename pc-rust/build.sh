#!/usr/bin/env bash
# 构建 Rust PC 版：产出单文件 exe 并复制到本目录根目录
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

command -v cargo >/dev/null 2>&1 || { echo "未找到 cargo，请先安装 Rust：https://rustup.rs/"; exit 1; }
echo "编译中（首次会下载依赖，请稍候）…"
cargo build --release
cp -f target/release/file-share-pc.exe ./file-share-pc.exe
echo ""
echo "构建完成：$(pwd)/file-share-pc.exe"
ls -l file-share-pc.exe
