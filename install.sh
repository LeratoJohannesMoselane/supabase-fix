#!/bin/bash
# Alias to deploy.sh for familiarity: ./install.sh myapp 8000
# Same as ./deploy.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/deploy.sh" "$@"
