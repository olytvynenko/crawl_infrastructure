#!/bin/bash
#
# Script to start the crawl pipeline with production configuration
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

# Production configuration
PROD_INPUT='{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": true,
    "cluster_create": true,
    "crawler_build": true,
    "crawl_hidden_dom2": true,
    "crawl_non_hidden_dom2": true,
    "crawl_wordpress_detect": true,
    "crawl_sitemap_hidden": true,
    "crawl_sitemap_non_hidden": true,
    "delta_upsert": true,
    "generate_sitemap_seeds": true,
    "crawl_urls_hidden": true,
    "crawl_urls_non_hidden": true,
    "cluster_resize": false,
    "cluster_destroy": true,
    "schedule_s3_deletion": true
  },
  "s3_deletion_config": {
    "enabled": true,
    "folders": [
      "update/seed/",
      "update/results/"
    ],
    "deletion_delay_seconds": 86400,
    "check_delay_seconds": 86520
  }
}'

echo -e "${YELLOW}Starting crawl pipeline with PRODUCTION configuration...${NC}"
echo "State Machine: ${STATE_MACHINE_ARN}"
echo ""
echo -e "${RED}WARNING: Production Configuration${NC}"
echo "- Data paths: update/seed/ and update/results/"
echo "- S3 deletion delay: 24 hours"
echo "- All crawl stages enabled"
echo ""

# Confirm before starting
read -p "Are you sure you want to start the PRODUCTION pipeline? (yes/N) " -r
if [[ ! $REPLY == "yes" ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

# Double confirm for production
read -p "Type 'PRODUCTION' to confirm: " -r
if [[ ! $REPLY == "PRODUCTION" ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

# Start execution
echo -e "${YELLOW}Starting execution...${NC}"
EXECUTION_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "${STATE_MACHINE_ARN}" \
    --input "${PROD_INPUT}" \
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