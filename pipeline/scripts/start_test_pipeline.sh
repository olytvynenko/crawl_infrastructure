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
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:crawl-build-state-machine"

# Test configuration - WordPress crawl with data processing
TEST_INPUT='{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": false,
    "cluster_create": true,
    "crawl_wpapi_hidden": true,
    "crawl_wpapi_non_hidden": true,
    "crawl_sitemap_hidden": true,
    "crawl_sitemap_non_hidden": true,
    "delta_upsert": false,
    "generate_sitemap_seeds": true,
    "crawl_urls_hidden": true,
    "crawl_urls_non_hidden": true,
    "sitemaps_delta_upsert": false,
    "cluster_destroy": true,
    "schedule_s3_deletion": true
  },
  "s3_deletion_config": {
    "folders": [
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
echo "- Stages: WordPress API crawl (hidden + non-hidden) + Delta upsert"
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