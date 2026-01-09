#!/bin/bash

# --- Configuration ---
KERNEL_ROOT=$(pwd)
KERNEL_NAME="Maximum-KernelSU-SUSFS"
DEVICE="gs201"
DATE=$(date +"%Y%m%d")
LOG_FILE="$KERNEL_ROOT/build.log"
LAST_SHA_FILE="$KERNEL_ROOT/.acacia_last_sha"

# Directories
TOOLCHAIN_DIR="$KERNEL_ROOT/toolchain"
ANYKERNEL_DIR="$KERNEL_ROOT/AnyKernel3"

# Defconfig
DEFCONFIG="gs201_defconfig"

# --- Helper ---
info() { echo -e "\n\e[1;36m==>\e[0m \e[1m$1\e[0m"; }

info "Building $KERNEL_NAME for $DEVICE"

# --- Telegram Functions ---
tg_msg() {
    [ -z "$TG_BOT_TOKEN" ] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$1" \
        -d parse_mode="Markdown" > /dev/null
}

tg_start_monitor() {
    [ -z "$TG_BOT_TOKEN" ] && return
    
    RES=$(curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="Build initiated: $KERNEL_NAME ($DEVICE)" \
        -d parse_mode="Markdown")
        
    TG_LIVE_MSG_ID=$(echo "$RES" | jq -r '.result.message_id')
    
    (
        while true; do
            sleep 5
            if [ -f "$LOG_FILE" ]; then
                LOG_TAIL=$(tail -n 10 "$LOG_FILE")
                TIME=$(date +"%H:%M:%S")
                
                JSON=$(jq -n \
                    --arg cid "$TG_CHAT_ID" \
                    --arg mid "$TG_LIVE_MSG_ID" \
                    --arg txt "Building... [$TIME]
\`\`\`
$LOG_TAIL
\`\`\`" \
                    '{chat_id: $cid, message_id: $mid, text: $txt, parse_mode: "Markdown"}')

                curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/editMessageText" \
                    -H "Content-Type: application/json" \
                    -d "$JSON" > /dev/null
            fi
        done
    ) &
    TG_MONITOR_PID=$!
}

tg_stop_monitor() {
    if [ -n "$TG_MONITOR_PID" ]; then
        kill "$TG_MONITOR_PID" 2>/dev/null
        wait "$TG_MONITOR_PID" 2>/dev/null
    fi
}

tg_upload_log() {
    [ -z "$TG_BOT_TOKEN" ] && return
    tg_msg "Build failed. Uploading log..."
    curl -s -F chat_id="$TG_CHAT_ID" \
         -F document=@"$LOG_FILE" \
         -F caption="Build Log (Failure)" \
         "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
}

trap 'tg_stop_monitor; echo "Build cancelled."; exit 130' INT

# --- Dependencies ---
info "Checking for build dependencies"
DEPS=("curl" "jq" "tar" "zip" "lz4")
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo "Error: Required command '$dep' is not installed."
        exit 1
    fi
done

# --- Toolchain Setup ---
info "Setting up toolchain"
GCC_DIR="$TOOLCHAIN_DIR/gcc-14.2.0-nolibc/aarch64-linux"

if [ ! -d "$GCC_DIR/bin" ]; then
    info "Downloading GCC 14.2.0 toolchain..."
    mkdir -p "$TOOLCHAIN_DIR"
    cd "$TOOLCHAIN_DIR"
    
    wget -q https://www.kernel.org/pub/tools/crosstool/files/bin/x86_64/14.2.0/x86_64-gcc-14.2.0-nolibc-aarch64-linux.tar.gz -O gcc.tar.gz || exit 1
    gunzip gcc.tar.gz
    tar -xf gcc.tar || exit 1
    rm -f gcc.tar
    
    cd "$KERNEL_ROOT"
fi

export PATH="$GCC_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-
export KBUILD_BUILD_USER="zen"
export KBUILD_BUILD_HOST="Github"

GCC_PATH="$GCC_DIR/bin/aarch64-linux-"

info "GCC version: $(aarch64-linux-gcc --version | head -1)"

# --- Build Start ---
info "Cleaning..."
rm -f "$LOG_FILE"
touch "$LOG_FILE"

tg_start_monitor

# Config
info "Generating config..."
make CROSS_COMPILE=${GCC_PATH} CC=${GCC_PATH}gcc ARCH=arm64 "$DEFCONFIG" -j$(nproc) 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -ne 0 ]; then tg_stop_monitor; tg_upload_log; exit 1; fi

# Compilation
info "Starting Compilation..."
make CROSS_COMPILE=${GCC_PATH} CC=${GCC_PATH}gcc ARCH=arm64 -j$(nproc) 2>&1 | tee -a "$LOG_FILE"
BUILD_STATUS=${PIPESTATUS[0]}

if [ $BUILD_STATUS -eq 0 ]; then
    tg_stop_monitor
    
    if [ -f "arch/arm64/boot/Image.lz4" ]; then
        info "Kernel Image.lz4 built successfully!"
    elif [ -f "arch/arm64/boot/Image" ]; then
        info "Compressing Image to Image.lz4..."
        lz4 -f "arch/arm64/boot/Image" "arch/arm64/boot/Image.lz4"
    else
        echo "Error: No kernel image found!"
        tg_upload_log
        exit 1
    fi
else
    tg_stop_monitor
    echo "=== BUILD FAILED - Last 50 error lines ==="
    grep -i "error:" "$LOG_FILE" | tail -50
    tg_upload_log
    exit 1
fi

# --- Packaging ---
info "Packaging Kernel"

if [ ! -d "$ANYKERNEL_DIR" ]; then
    echo "Error: AnyKernel3 not found."
    exit 1
fi

# Check if Image is freshly built (within last 5 minutes)
IMAGE_FILE="$KERNEL_ROOT/arch/arm64/boot/Image.lz4"
[ ! -f "$IMAGE_FILE" ] && IMAGE_FILE="$KERNEL_ROOT/arch/arm64/boot/Image"

if [ -f "$IMAGE_FILE" ]; then
    IMAGE_AGE=$(( $(date +%s) - $(stat -c %Y "$IMAGE_FILE") ))
    if [ $IMAGE_AGE -gt 600 ]; then
        echo "Error: Image is stale (${IMAGE_AGE}s old). Build may have failed."
        exit 1
    fi
else
    echo "Error: No kernel image found!"
    exit 1
fi

cd "$ANYKERNEL_DIR"
rm -f Image* dtb *.zip 2>/dev/null

# Copy kernel image
if [ -f "$KERNEL_ROOT/arch/arm64/boot/Image.lz4" ]; then
    cp "$KERNEL_ROOT/arch/arm64/boot/Image.lz4" ./Image.lz4
else
    echo "Error: Image.lz4 not found."
    exit 1
fi

# Copy DTB files
if [ -d "$KERNEL_ROOT/google-devices/$DEVICE/dts" ]; then
    cat "$KERNEL_ROOT/google-devices/$DEVICE/dts"/*.dtb > ./dtb 2>/dev/null || echo "Warning: No DTB files found"
fi

SHORT_SHA=$(git -C "$KERNEL_ROOT" rev-parse --short HEAD)
ZIP_NAME="Acacia-${KERNEL_NAME}-${DEVICE}-${SHORT_SHA}-${DATE}.zip"

zip -r9 "$ZIP_NAME" . -x ".git" -x "README.md" -x "*placeholder" -x "*.zip"
mv "$ZIP_NAME" "$KERNEL_ROOT/"
cd "$KERNEL_ROOT"

echo "Build Complete: $ZIP_NAME"

# --- Upload Success ---
if [ -n "$TG_BOT_TOKEN" ]; then
    if [ -f "$LAST_SHA_FILE" ]; then
        LAST_SHA=$(cat "$LAST_SHA_FILE")
        CHANGELOG=$(git log --pretty=format:"%h: %s" "$LAST_SHA..HEAD")
        [ -z "$CHANGELOG" ] && CHANGELOG="No new commits."
    else
        CHANGELOG=$(git log --pretty=format:"%h: %s" -n 5)
    fi

    CAPTION="Build complete: ${ZIP_NAME}

${CHANGELOG}"

    info "Uploading $ZIP_NAME to Telegram..."
    for i in 1 2 3; do
        UPLOAD_RESULT=$(curl -s --max-time 300 -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP_NAME" -F caption="$CAPTION" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument")
        if echo "$UPLOAD_RESULT" | jq -e '.ok == true' > /dev/null 2>&1; then
            echo "Upload successful!"
            break
        else
            echo "Upload attempt $i failed: $UPLOAD_RESULT"
            [ $i -lt 3 ] && sleep 5
        fi
    done
    
    if [ -f ".config" ]; then
        curl -s --max-time 60 -F chat_id="$TG_CHAT_ID" -F document=@".config" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
    fi

    git rev-parse HEAD > "$LAST_SHA_FILE"
fi
