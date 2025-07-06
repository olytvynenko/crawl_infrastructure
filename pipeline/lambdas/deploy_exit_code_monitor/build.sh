#!/bin/bash
# Build deployment package for deploy_exit_code_monitor Lambda

cd "$(dirname "$0")"

# Clean up
rm -f deploy_exit_code_monitor.zip

# Create deployment package
zip deploy_exit_code_monitor.zip deploy_exit_code_monitor.py

echo "Created deploy_exit_code_monitor.zip"
ls -lh deploy_exit_code_monitor.zip