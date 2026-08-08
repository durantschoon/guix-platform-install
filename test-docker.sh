#!/usr/bin/env bash
# Docker-based test runner for guix-platform-install
# This script runs all tests in a clean Docker environment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Usage message
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  test    - Run all tests in Docker (default)"
    echo "  shell   - Open interactive shell in Docker container"
    echo "  build   - Build Docker test image"
    echo "  clean   - Remove Docker test containers and volumes"
    echo ""
    echo "Examples:"
    echo "  $0           # Run tests"
    echo "  $0 shell     # Debug in container"
    echo "  $0 clean     # Clean up Docker resources"
}

# Check if Docker is installed
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed${NC}"
        echo "Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo -e "${RED}Error: Docker Compose is not installed${NC}"
        echo "Please install Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

# Determine docker compose command (v1 vs v2)
get_compose_cmd() {
    if docker compose version &> /dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        echo "docker compose"  # Default, will fail with helpful error
    fi
}

# Build Docker test image
build_image() {
    echo -e "${BLUE}Building Docker test image...${NC}"
    COMPOSE_CMD=$(get_compose_cmd)
    $COMPOSE_CMD -f docker-compose.test.yml build test
    echo -e "${GREEN}✓ Docker test image built successfully${NC}"
}

# Run tests in Docker
run_tests() {
    echo -e "${BLUE}Running tests in Docker container...${NC}"
    echo ""

    COMPOSE_CMD=$(get_compose_cmd)

    # Run tests and capture exit code
    if $COMPOSE_CMD -f docker-compose.test.yml run --rm test; then
        echo ""
        echo -e "${GREEN}✓ All Docker tests passed!${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}✗ Docker tests failed${NC}"
        return 1
    fi
}

# Open interactive shell
run_shell() {
    echo -e "${BLUE}Opening interactive shell in Docker container...${NC}"
    echo "Type 'exit' to leave the container"
    echo ""

    COMPOSE_CMD=$(get_compose_cmd)
    $COMPOSE_CMD -f docker-compose.test.yml run --rm shell
}

# Clean up Docker resources
clean() {
    echo -e "${YELLOW}Cleaning up Docker resources...${NC}"

    COMPOSE_CMD=$(get_compose_cmd)

    # Stop and remove containers
    $COMPOSE_CMD -f docker-compose.test.yml down

    # Remove volumes
    echo "Removing volumes (this will clear Go cache)..."
    docker volume rm guix-platform-install_go-cache 2>/dev/null || true
    docker volume rm guix-platform-install_go-tmp 2>/dev/null || true

    # Remove test image
    echo "Removing test image..."
    docker rmi guix-platform-install-test 2>/dev/null || true

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

# Main script
check_docker

COMMAND=${1:-test}

case "$COMMAND" in
    test)
        build_image
        run_tests
        ;;
    shell)
        build_image
        run_shell
        ;;
    build)
        build_image
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        echo ""
        usage
        exit 1
        ;;
esac
