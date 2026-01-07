#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -e

KERNEL_DIR=$(pwd)
DEFCONFIG="gs201_defconfig"
DEVICE="gs201"
KERNEL_NAME="Sultan-KernelSU-SUSFS"
ANYKERNEL_DIR="${KERNEL_DIR}/AnyKernel3"
OUT_DIR="${KERNEL_DIR}/out"
DATE=$(date +"%Y%m%d-%H%M")
KERNEL_VERSION=$(make kernelversion 2>/dev/null)
ZIP_NAME="${KERNEL_NAME}-${DEVICE}-${DATE}.zip"

export ARCH=arm64
export SUBARCH=arm64

TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

download_clang()
{
	echo "Downloading latest AOSP Clang..."
	mkdir -p "${KERNEL_DIR}/toolchain"
	cd "${KERNEL_DIR}/toolchain"

	CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz"

	if [ ! -d "clang" ]; then
		mkdir -p clang
		curl -LSs "$CLANG_URL" | tar -xz -C clang
	fi

	cd "${KERNEL_DIR}"

	export PATH="${KERNEL_DIR}/toolchain/clang/bin:$PATH"
	export CLANG_TRIPLE=aarch64-linux-gnu-
	export CROSS_COMPILE=aarch64-linux-gnu-
	export CC=clang
	export LD=ld.lld
	export AR=llvm-ar
	export NM=llvm-nm
	export OBJCOPY=llvm-objcopy
	export OBJDUMP=llvm-objdump
	export STRIP=llvm-strip
}

get_changelog()
{
	echo "Getting commit changelog..."
	LAST_COMMITS=$(git log --oneline -10 --no-merges)
	echo "$LAST_COMMITS"
}

build_kernel()
{
	echo "Building kernel..."

	rm -rf "$OUT_DIR"
	mkdir -p "$OUT_DIR"

	make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 "$DEFCONFIG"

	make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc)

	if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
		echo "Kernel built successfully!"
	else
		echo "Kernel build failed!"
		exit 1
	fi
}

make_zip()
{
	echo "Creating flashable zip..."

	cd "$ANYKERNEL_DIR"
	git clean -fdx

	cp "${OUT_DIR}/arch/arm64/boot/Image" ./

	if [ -f "${OUT_DIR}/arch/arm64/boot/Image.lz4" ]; then
		cp "${OUT_DIR}/arch/arm64/boot/Image.lz4" ./
	fi

	zip -r9 "${KERNEL_DIR}/${ZIP_NAME}" * -x .git README.md *placeholder

	cd "$KERNEL_DIR"
	echo "Zip created: ${ZIP_NAME}"
}

send_telegram()
{
	if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
		echo "Telegram credentials not set, skipping upload"
		return
	fi

	echo "Sending to Telegram..."

	CHANGELOG=$(get_changelog)

	MESSAGE="<b>🔥 ${KERNEL_NAME} Build</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Kernel:</b> <code>${KERNEL_VERSION}</code>
<b>Date:</b> <code>${DATE}</code>

<b>📝 Changelog:</b>
<code>${CHANGELOG}</code>"

	curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
		-F chat_id="${TELEGRAM_CHAT_ID}" \
		-F document=@"${KERNEL_DIR}/${ZIP_NAME}" \
		-F caption="${MESSAGE}" \
		-F parse_mode="HTML"

	echo "Uploaded to Telegram!"
}

clean()
{
	echo "Cleaning..."
	rm -rf "$OUT_DIR"
	rm -f "${KERNEL_DIR}"/*.zip
}

case "$1" in
	clean)
		clean
		;;
	changelog)
		get_changelog
		;;
	*)
		download_clang
		build_kernel
		make_zip
		send_telegram
		echo "Done! Zip: ${ZIP_NAME}"
		;;
esac
