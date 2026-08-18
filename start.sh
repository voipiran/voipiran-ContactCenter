#!/bin/bash

# OpDesk production start script.
# VOIPIRAN: Frontend must be built before deployment.
# VOIPIRAN: Production server must never build the frontend.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

MODE="production"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dev)
      MODE="dev"
      shift
      ;;
    -p|--production|--prod)
      MODE="production"
      shift
      ;;
    *)
      echo -e "${RED}Usage: $0 [-p|--production] | [-d|--dev]${NC}"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

cd "$PROJECT_ROOT" || {
    echo -e "${RED}Error: Cannot access $PROJECT_ROOT${NC}"
    exit 1
}

# Load NVM for development mode only.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

if [[ "$MODE" == "production" ]]; then

  # VOIPIRAN: Production server uses pre-built frontend.
  # Frontend must be built before deployment.
  # Do not run npm build on the production server.

  DIST_INDEX="$PROJECT_ROOT/frontend/dist/index.html"

  if [ ! -f "$DIST_INDEX" ]; then
    echo -e "${RED}Error: frontend/dist/index.html not found${NC}"
    exit 1
  fi

  echo -e "${GREEN}[VOIPIRAN]${NC} Production mode: using pre-built frontend."

fi

cd "$PROJECT_ROOT/backend" || {
    echo -e "${RED}Error: Backend directory not found${NC}"
    exit 1
}

python server.py &
BACKEND_PID=$!

if [[ "$MODE" == "production" ]]; then

    echo -e "${GREEN}[OpDesk]${NC} Backend serving from frontend/dist."
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"

    trap "kill $BACKEND_PID 2>/dev/null; exit" SIGINT SIGTERM

    wait $BACKEND_PID

else

    echo -e "${BLUE}[OpDesk]${NC} Development mode: starting Vite dev server..."

    cd "$PROJECT_ROOT/frontend" || {
        echo -e "${RED}Error: Frontend directory not found${NC}"
        kill $BACKEND_PID 2>/dev/null
        exit 1
    }

    npm run dev -- --host &
    FRONTEND_PID=$!

    echo -e "${GREEN}[OpDesk]${NC} Backend PID: $BACKEND_PID, Frontend PID: $FRONTEND_PID"

    trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit" SIGINT SIGTERM

    wait
fi