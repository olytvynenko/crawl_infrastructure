#!/bin/bash

# Script to run Terraform operations via CodeBuild

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 {plan|apply|destroy} {nv|nc|ohio|oregon|all}"
    echo ""
    echo "Actions:"
    echo "  plan    - Show what changes will be made"
    echo "  apply   - Apply the changes (create/update resources)"
    echo "  destroy - Destroy the resources"
    echo ""
    echo "Clusters:"
    echo "  nv      - Nevada cluster"
    echo "  nc      - North California cluster"
    echo "  ohio    - Ohio cluster"
    echo "  oregon  - Oregon cluster"
    echo "  all     - All clusters (nv,nc,ohio,oregon)"
    echo ""
    echo "Example: $0 plan nv"
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

ACTION=$1
CLUSTERS=$2

# Validate action
case $ACTION in
    plan|apply|destroy)
        ;;
    *)
        echo -e "${RED}Error: Invalid action '$ACTION'${NC}"
        usage
        ;;
esac

# Validate clusters
case $CLUSTERS in
    nv|nc|ohio|oregon)
        ;;
    all)
        CLUSTERS="nv,nc,ohio,oregon"
        ;;
    *)
        echo -e "${RED}Error: Invalid cluster '$CLUSTERS'${NC}"
        usage
        ;;
esac

echo -e "${YELLOW}Starting CodeBuild for action: ${GREEN}$ACTION${NC} on clusters: ${GREEN}$CLUSTERS${NC}"

# Run CodeBuild
aws codebuild start-build \
    --project-name cluster-manager \
    --environment-variables-override \
        name=ACTION,value=$ACTION \
        name=CLUSTERS,value=$CLUSTERS \
    --query 'build.{id:id,status:buildStatus}' \
    --output table

if [ $? -eq 0 ]; then
    echo -e "${GREEN}CodeBuild job started successfully!${NC}"
    echo ""
    echo "To monitor the build status, run:"
    echo "aws codebuild batch-get-builds --ids <build-id> --query 'builds[0].buildStatus'"
else
    echo -e "${RED}Failed to start CodeBuild job${NC}"
    exit 1
fi