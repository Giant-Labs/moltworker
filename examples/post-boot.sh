#!/bin/bash
# Post-boot hook for Moltbot container
#
# This script runs after config setup but before the gateway starts.
# Place this file at /data/moltbot/hooks/post-boot.sh on R2.
#
# Use cases:
# - Install additional packages
# - Set up environment variables
# - Run custom initialization scripts
# - Apply temporary fixes without redeploying

echo "[post-boot] Running custom hook..."

# Example: Install a package (uncomment to use)
# apt-get update && apt-get install -y some-package

# Example: Set an environment variable
# export MY_CUSTOM_VAR="value"

# Example: Create a custom directory
# mkdir -p /root/clawd/custom

echo "[post-boot] Hook complete"
