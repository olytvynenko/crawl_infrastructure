#!/bin/bash
#
# Script to start the crawl pipeline with test configuration
#

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}

# State Machine ARN
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:crawl-pipeline"

# Test configuration
TEST_INPUT='{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": false,
    "cluster_create": true,
    "crawler_build": true,
    "crawl_hidden_dom2": true,
    "crawl_non_hidden_dom2": true,
    "crawl_wordpress_detect": false,
    "crawl_sitemap_hidden": false,
    "crawl_sitemap_non_hidden": false,
    "delta_upsert": false,
    "generate_sitemap_seeds": false,
    "crawl_urls_hidden": false,
    "crawl_urls_non_hidden": false,
    "cluster_resize": false,
    "cluster_destroy": true,
    "schedule_s3_deletion": true
  },
  "s3_deletion_config": {
    "enabled": true,
    "folders": [
      "test/seed/",
      "test/results/"
    ],
    "deletion_delay_seconds": 300,
    "check_delay_seconds": 420
  }
}'

echo -e "${YELLOW}Starting crawl pipeline with test configuration...${NC}"
echo "State Machine: ${STATE_MACHINE_ARN}"
echo ""
echo "Test Configuration:"
echo "- Data paths: test/seed/ and test/results/"
echo "- S3 deletion delay: 5 minutes"
echo "- Stages: Limited crawl stages for testing"
echo ""

# Confirm before starting
read -p "Do you want to start the test pipeline? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

# Start execution
echo -e "${YELLOW}Starting execution...${NC}"
EXECUTION_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "${STATE_MACHINE_ARN}" \
    --input "${TEST_INPUT}" \
    --query 'executionArn' \
    --output text)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Pipeline started successfully!${NC}"
    echo "Execution ARN: ${EXECUTION_ARN}"
    echo ""
    echo "View execution in console:"
    echo "https://console.aws.amazon.com/states/home?region=${REGION}#/executions/details/${EXECUTION_ARN}"
else
    echo -e "${RED}✗ Failed to start pipeline${NC}"
    exit 1
fi