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

download_clang()
{
	tg_update "Downloading AOSP Clang..."
	echo "Downloading latest AOSP Clang..."
	mkdir -p "${KERNEL_DIR}/toolchain"
	cd "${KERNEL_DIR}/toolchain"

	CLANG_VER="clang-r522817"
	CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/${CLANG_VER}.tar.gz"

	if [ ! -d "${CLANG_VER}" ]; then
		echo "Downloading ${CLANG_VER}..."
		mkdir -p "${CLANG_VER}"
		curl -LSs "$CLANG_URL" | tar -xz -C "${CLANG_VER}"
	fi

	cd "${KERNEL_DIR}"

	export PATH="${KERNEL_DIR}/toolchain/${CLANG_VER}/bin:$PATH"
	export CLANG_TRIPLE=aarch64-linux-gnu-
	export CROSS_COMPILE=aarch64-linux-gnu-
	export CC=clang
	export LD=ld.lld
	export AR=llvm-ar
	export NM=llvm-nm
	export OBJCOPY=llvm-objcopy
	export OBJDUMP=llvm-objdump
	export STRIP=llvm-strip

	echo "Clang version: $(clang --version | head -1)"
	tg_update "Clang ready ✓"
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

	tg_update "Generating defconfig..."
	make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 "$DEFCONFIG"

	tg_update "Compiling kernel..."
	make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc)

	if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
		echo "Kernel built successfully!"
		tg_update "Kernel compiled ✓"
	else
		tg_update "❌ Build failed!"
		echo "Kernel build failed!"
		exit 1
	fi
}

make_zip()
{
	tg_update "Creating flashable zip..."
	echo "Creating flashable zip..."

	cd "$ANYKERNEL_DIR"
	git clean -fdx

	if [ -f "${OUT_DIR}/arch/arm64/boot/Image.lz4" ]; then
		cp "${OUT_DIR}/arch/arm64/boot/Image.lz4" ./Image.lz4
		echo "Copied Image.lz4"
	else
		echo "Image.lz4 not found!"
		exit 1
	fi

	echo "Concatenating DTB files..."
	cat ${OUT_DIR}/google-devices/gs201/dts/*.dtb > ./dtb
	echo "Created dtb"

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
		download_clang
		build_kernel
		make_zip
		send_telegram
		echo "Done! Zip: ${ZIP_NAME}"
		;;
esac
