#!/bin/bash

if [[ $(id -u) != "0" ]]; then
   echo "Please run as root (or use sudo)"
   exit 1 
fi

cd "$(dirname "$0")" || exit 1

#=============================================================================
#================================= CONSTANTS =================================
#=============================================================================

RED='\033[0;31m'
NC='\033[0m'

DEFAULT_IMAGE_NAME="so2/so2-assignments"
DEFAULT_TAG='latest'
DEFAULT_REGISTRY='gitlab.cs.pub.ro:5050'
SO2_WORKSPACE="/linux/tools/labs"
SO2_VOLUME="SO2_DOCKER_VOLUME"

#=============================================================================
#=================================== UTILS ===================================
#=============================================================================

LOG_INFO() {
    echo -e "[$(date +%FT%T)] [INFO] $1"
}

LOG_FATAL() {
    echo -e "[$(date +%FT%T)] [${RED}FATAL${NC}] $1"
    exit 1
}

print_help() {
    echo "Usage:"
    echo "local.sh docker interactive [--privileged] [--allow-gui]"
    echo ""
    echo "      --privileged - run a privileged container. This allows the use of KVM (if available)"
    echo "      --allow-gui - run the docker such that it can open GUI apps"
    echo ""
}

#=============================================================================
#================================ CORE LOGIC =================================
#=============================================================================

docker_interactive() {
    local full_image_name="${DEFAULT_REGISTRY}/${DEFAULT_IMAGE_NAME}:${DEFAULT_TAG}"
    local executable="/bin/bash"
    local container_name="so2-lab"
    local privileged=""
    local allow_gui=false

    while [[ $# -gt 0 ]]; do
        case $1 in
        --privileged) privileged="--privileged" ;;
        --allow-gui)  allow_gui=true ;;
        *) print_help; exit 1 ;;
        esac
        shift
    done

    # 1. 检查镜像
    if [[ $(docker images -q "$full_image_name" 2> /dev/null) == "" ]]; then
        LOG_INFO "Pulling image $full_image_name..."
        docker pull "$full_image_name"
    fi

    # 2. 准备数据卷
    if ! docker volume inspect $SO2_VOLUME >/dev/null 2>&1; then
        LOG_INFO "Creating volume $SO2_VOLUME"
        docker volume create $SO2_VOLUME
        local vol_mount=$(docker inspect $SO2_VOLUME --format '{{.Mountpoint}}')
        chmod 777 -R "$vol_mount"
    fi

    # 3. 清理已存在的同名容器（防止冲突）
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        LOG_INFO "Removing existing container: $container_name"
        docker rm -f "$container_name"
    fi

    # 4. GUI 环境配置
    local extra_args=""
    if $allow_gui; then
        LOG_INFO "Configuring GUI environment..."
        
        # 处理 WSL 兼容性
        if grep -qi microsoft /proc/version; then
            export DISPLAY="$(ip r show default | awk '{print $3}'):0.0"
        fi

        if [[ -z "$DISPLAY" ]]; then
            LOG_FATAL "DISPLAY is not set. GUI cannot start."
        fi

        # 核心修复：创建一个临时的、且 Docker 可读的 Xauthority 文件
        XAUTH_TMP="/tmp/.docker.xauth"
        rm -f "$XAUTH_TMP"
        touch "$XAUTH_TMP"
        # 允许 X11 连接（包含网络权限修复）
        xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_TMP" nmerge - 2>/dev/null
        chmod 644 "$XAUTH_TMP"

        extra_args="--net=host --env=DISPLAY --env=XAUTHORITY=$XAUTH_TMP -v $XAUTH_TMP:$XAUTH_TMP"
        
        # 允许本地 Root 访问 X11 (备选方案)
        xhost +local:root &> /dev/null
    else
        # 非 GUI 模式保留原有的网络配置
        extra_args="--cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun"
    fi

    # 5. 启动容器
    # 添加 --restart unless-stopped 保证重启后自动尝试恢复运行
    LOG_INFO "Starting container $container_name..."
    docker run $privileged -itd \
        --name "$container_name" \
        --restart no \
        $extra_args \
        -v $SO2_VOLUME:/linux \
        --workdir "$SO2_WORKSPACE" \
        "$full_image_name" "$executable"

    LOG_INFO "Container is running. Use 'docker exec -it $container_name bash' to enter."
}

docker_main() {
    if [ "$1" = "interactive" ] ; then
        shift
        docker_interactive "$@"
    fi
}

if [ "$1" = "docker" ] ; then
    shift
    docker_main "$@"
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print_help
else
    print_help
fi