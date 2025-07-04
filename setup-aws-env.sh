#!/bin/bash

# AWS Environment Setup Script
# 
# Usage: 
# 1. Edit this file with your credentials
# 2. Run: source setup-aws-env.sh

# Replace these with your actual AWS credentials
export AWS_ACCESS_KEY_ID="REPLACE_WITH_YOUR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="REPLACE_WITH_YOUR_SECRET_KEY"
export AWS_DEFAULT_REGION="us-east-1"

# Verify the configuration
echo "Testing AWS configuration..."
aws sts get-caller-identity

if [ $? -eq 0 ]; then
    echo "✅ AWS credentials configured successfully!"
else
    echo "❌ AWS credentials configuration failed. Please check your credentials."
fi