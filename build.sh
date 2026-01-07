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

TELEGRAM_TOKEN="${TG_BOT_TOKEN:-8585670877:AAGFjf6V8GN5ERfAjspsnQqH-a3Jh4xyCWg}"
TELEGRAM_CHAT_ID="${TG_CHAT_ID:-7721220680}"
MSG_ID=""

tg_send()
{
	local message="$1"
	curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
		-d chat_id="${TELEGRAM_CHAT_ID}" \
		-d text="${message}" \
		-d parse_mode="HTML" \
		-d disable_web_page_preview="true"
}

tg_edit()
{
	local message="$1"
	curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/editMessageText" \
		-d chat_id="${TELEGRAM_CHAT_ID}" \
		-d message_id="${MSG_ID}" \
		-d text="${message}" \
		-d parse_mode="HTML" \
		-d disable_web_page_preview="true"
}

tg_start()
{
	local response
	response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
		-d chat_id="${TELEGRAM_CHAT_ID}" \
		-d text="<b>🔨 Build Started</b>%0A%0A<b>Device:</b> <code>${DEVICE}</code>%0A<b>Kernel:</b> <code>${KERNEL_VERSION}</code>%0A<b>Date:</b> <code>${DATE}</code>%0A%0A<b>Status:</b> <code>Initializing...</code>" \
		-d parse_mode="HTML")
	MSG_ID=$(echo "$response" | grep -o '"message_id":[0-9]*' | cut -d: -f2)
	echo "Build message ID: $MSG_ID"
}

tg_update()
{
	local status="$1"
	tg_edit "<b>🔨 Build In Progress</b>%0A%0A<b>Device:</b> <code>${DEVICE}</code>%0A<b>Kernel:</b> <code>${KERNEL_VERSION}</code>%0A<b>Date:</b> <code>${DATE}</code>%0A%0A<b>Status:</b> <code>${status}</code>"
}

download_toolchain()
{
	tg_update "Downloading GCC 14.2.0 toolchain..."
	echo "Downloading GCC 14.2.0 toolchain..."
	mkdir -p "${KERNEL_DIR}/toolchain"
	cd "${KERNEL_DIR}/toolchain"

	if [ ! -d "gcc-14.2.0-nolibc/aarch64-linux" ]; then
		echo "Downloading GCC 14.2.0..."
		wget -q https://www.kernel.org/pub/tools/crosstool/files/bin/x86_64/14.2.0/x86_64-gcc-14.2.0-nolibc-aarch64-linux.tar.gz -O gcc.tar.gz
		gunzip gcc.tar.gz
		tar -xf gcc.tar
		rm -f gcc.tar
	fi

	cd "${KERNEL_DIR}"

	export PATH="${KERNEL_DIR}/toolchain/gcc-14.2.0-nolibc/aarch64-linux/bin:$PATH"
	export CROSS_COMPILE=aarch64-linux-

	echo "GCC version: $(aarch64-linux-gcc --version | head -1)"
	tg_update "GCC ready ✓"
}

get_changelog()
{
	LAST_COMMITS=$(git log --oneline -10 --no-merges)
	echo "$LAST_COMMITS"
}

build_kernel()
{
	tg_update "Building kernel..."
	echo "Building kernel..."

	rm -rf "$OUT_DIR"
	mkdir -p "$OUT_DIR"

	export KBUILD_BUILD_USER="zen"
	export KBUILD_BUILD_HOST="Github"

	GCC_PATH="${KERNEL_DIR}/toolchain/gcc-14.2.0-nolibc/aarch64-linux/bin/aarch64-linux-"
	BUILD_LOG="${KERNEL_DIR}/build.log"

	tg_update "Generating defconfig..."
	make CROSS_COMPILE=${GCC_PATH} CC=${GCC_PATH}gcc ARCH=arm64 "$DEFCONFIG" -j$(nproc) 2>&1 | tee -a "$BUILD_LOG" | tail -5

	tg_update "Compiling kernel..."
	if make CROSS_COMPILE=${GCC_PATH} CC=${GCC_PATH}gcc ARCH=arm64 -j$(nproc) 2>&1 | tee -a "$BUILD_LOG"; then
		if [ -f "arch/arm64/boot/Image.lz4" ]; then
			echo "Kernel built successfully!"
			tg_update "Kernel compiled ✓"
		elif [ -f "arch/arm64/boot/Image" ]; then
			echo "Compressing Image to Image.lz4..."
			lz4 -f "arch/arm64/boot/Image" "arch/arm64/boot/Image.lz4"
			tg_update "Kernel compiled ✓"
		else
			tg_update "❌ Build failed! No Image found"
			send_build_error "No kernel image produced"
			exit 1
		fi
	else
		tg_update "❌ Build failed!"
		send_build_error "Compilation error"
		exit 1
	fi
}

send_build_error()
{
	local reason="$1"
	local error_log=$(tail -50 "${KERNEL_DIR}/build.log" 2>/dev/null || echo "No log available")

	curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
		-d chat_id="${TELEGRAM_CHAT_ID}" \
		-d text="<b>❌ Build Failed</b>%0A%0A<b>Reason:</b> <code>${reason}</code>%0A%0A<b>Last 50 lines:</b>%0A<pre>${error_log}</pre>" \
		-d parse_mode="HTML"
}

make_zip()
{
	tg_update "Creating flashable zip..."
	echo "Creating flashable zip..."

	cd "$ANYKERNEL_DIR"
	git clean -fdx

	if [ -f "${KERNEL_DIR}/out/arch/arm64/boot/Image.lz4" ]; then
		cp "${KERNEL_DIR}/out/arch/arm64/boot/Image.lz4" ./Image.lz4
		echo "Copied Image.lz4"
	elif [ -f "${KERNEL_DIR}/arch/arm64/boot/Image.lz4" ]; then
		cp "${KERNEL_DIR}/arch/arm64/boot/Image.lz4" ./Image.lz4
		echo "Copied Image.lz4"
	else
		echo "Image.lz4 not found!"
		exit 1
	fi

	echo "Concatenating DTB files..."
	cat ${KERNEL_DIR}/out/google-devices/gs201/dts/*.dtb > ./dtb 2>/dev/null || \
	cat ${KERNEL_DIR}/google-devices/gs201/dts/*.dtb > ./dtb 2>/dev/null || \
	echo "Warning: No DTB files found"

	zip -r9 "${KERNEL_DIR}/${ZIP_NAME}" ./*

	cd "$KERNEL_DIR"
	echo "Zip created: ${ZIP_NAME}"
	tg_update "Zip created ✓"
}

send_telegram()
{
	tg_update "Uploading to Telegram..."
	echo "Sending to Telegram..."

	CHANGELOG=$(get_changelog)

	MESSAGE="<b>✅ ${KERNEL_NAME} Build Complete</b>

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
		tg_start
		download_toolchain
		build_kernel
		make_zip
		send_telegram
		echo "Done! Zip: ${ZIP_NAME}"
		;;
esac
