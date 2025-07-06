# Crawl Infrastructure - Comprehensive Documentation

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Architecture](#system-architecture)
3. [Infrastructure Components](#infrastructure-components)
4. [Data Processing Pipeline](#data-processing-pipeline)
5. [Deployment Guide](#deployment-guide)
6. [Configuration Reference](#configuration-reference)
7. [Monitoring and Alerting](#monitoring-and-alerting)
8. [Security Analysis](#security-analysis)
9. [Cost Optimization](#cost-optimization)
10. [Troubleshooting Guide](#troubleshooting-guide)
11. [Development Guidelines](#development-guidelines)
12. [TODOs and Recommendations](#todos-and-recommendations)

---

## 1. Executive Summary

The Crawl Infrastructure project is an enterprise-grade, distributed web crawling system built on AWS. It leverages Kubernetes (EKS) for compute, AWS Step Functions for orchestration, and Delta Lake for data processing.

### Key Features
- **Multi-region deployment** across 4 AWS regions
- **Auto-scaling** with Karpenter using ARM64 instances
- **Automated lifecycle** from cluster creation to destruction
- **IP abuse detection** with automatic node tainting
- **Cost-optimized** using spot instances and ARM architecture
- **Data deduplication** using Delta Lake technology

### Use Cases
- Large-scale web content crawling
- WordPress API data collection
- Sitemap processing and URL discovery
- Structured data extraction and storage

---

## 2. System Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS Step Functions                         │
│  (Orchestration Layer - Controls entire pipeline)            │
└─────────────────┬───────────────────────────┬────────────────┘
                  │                           │
     ┌────────────▼────────────┐  ┌──────────▼────────────┐
     │   EKS Clusters          │  │   Data Processing     │
     │  - Virginia (nv)        │  │  - AWS Glue Jobs      │
     │  - N. California (nc)   │  │  - Delta Lake         │
     │  - Ohio (ohio)          │  │  - S3 Storage         │
     │  - Oregon (oregon)      │  │  - DynamoDB Tables    │
     └────────────┬────────────┘  └───────────────────────┘
                  │
     ┌────────────▼────────────┐
     │  Kubernetes Jobs        │
     │  - Crawler pods         │
     │  - Exit code monitor    │
     │  - IP abuse detection   │
     └─────────────────────────┘
```

### 2.2 Component Interaction Flow

1. **CodeBuild** triggers cluster creation via `cluster_manager.py`
2. **Terraform** provisions EKS clusters with Karpenter
3. **Step Functions** orchestrates the crawling pipeline
4. **Kubernetes Jobs** execute crawling tasks
5. **Glue Jobs** process and deduplicate data
6. **Lambda Functions** handle notifications and cleanup
7. **CloudWatch** monitors system health

### 2.3 Technology Stack

- **Infrastructure**: Terraform 1.5+
- **Container Orchestration**: Kubernetes 1.27+ on EKS
- **Data Processing**: Apache Spark 3.3 on AWS Glue
- **Orchestration**: AWS Step Functions
- **Programming Languages**: Python 3.11, Go 1.21
- **Architecture**: ARM64 (Graviton processors)

---

## 3. Infrastructure Components

### 3.1 Cluster Management

#### cluster_manager.py
Main orchestrator for Terraform operations across workspaces.

**Key Functions:**
- `run_terraform()`: Executes Terraform commands
- `manage_cluster()`: Handles create/destroy/resize operations
- `get_clusters()`: Retrieves cluster list from Parameter Store

**Environment Variables:**
- `ACTION`: create, destroy, resize, plan
- `CLUSTERS`: Comma-separated list of regions
- `LEVEL`: Instance size tier (inst4, inst8, inst16)

#### Instance Tiers

| Tier | Memory | Instance Types | Use Case |
|------|--------|----------------|----------|
| inst4 | 4GB | t4g.medium, m6g.medium | Light workloads |
| inst8 | 8GB | r7g.medium, r6g.medium | Standard crawling |
| inst16 | 16GB | r7g.large | Heavy processing |

### 3.2 EKS Configuration

#### Network Architecture
- **VPC**: Custom VPC with 3 availability zones
- **Subnets**: Public (NAT gateway) and private (worker nodes)
- **Security Groups**: Restrictive ingress, open egress
- **DNS**: Cluster DNS disabled, using Google DNS (8.8.8.8)

#### Node Configuration
- **Managed Node Group**: For system components
- **Karpenter Nodes**: For crawler workloads
- **Taints**: Applied for IP abuse detection
- **Labels**: Region-specific for workload placement

### 3.3 Karpenter Autoscaler

**Configuration Files:**
- `nodepool.yaml`: Defines instance requirements
- `nodeclass.yaml`: EC2 configuration

**Key Settings:**
- Instance families: r7g, r6g, m7g, t4g (ARM64 only)
- Consolidation: Enabled after 30 seconds
- Expiration: Nodes expire after 30 minutes idle
- Limits: Configurable CPU and memory caps

**TODO:** Add pod disruption budgets for spot instances

### 3.4 Storage Systems

#### S3 Buckets
- **Primary**: `s3://linxact/`
- **Dataset Path**: `dataset-2409/`
- **Folder Structure**:
  ```
  dataset-2409/
  ├── update/          # Production data
  │   ├── seed/        # Input URLs
  │   └── results/     # Crawl output
  └── test/            # Test data
      ├── seed/
      └── results/
  ```

#### DynamoDB Tables
- **crawl-execution-checkpoints**: Pipeline state tracking
- **crawler-metrics**: Performance metrics
- **ip-abuse-tracking**: Blocked IP addresses

---

## 4. Data Processing Pipeline

### 4.1 Pipeline Stages

The Step Functions state machine orchestrates these stages:

1. **Crawler ARM Build** (`crawler_arm_build`)
   - Builds ARM64-compatible crawler container
   - Pushes to ECR repository
   - Optional stage for updates

2. **Cluster Creation** (`cluster_create`)
   - Provisions EKS clusters in selected regions
   - Configures Karpenter for autoscaling
   - Sets up monitoring components

3. **WordPress Crawling** (`crawl_hidden_dom2`, `crawl_non_hidden_dom2`)
   - Targets WordPress REST APIs
   - Separates hidden and visible content
   - Outputs to S3 in Parquet format

4. **WordPress Detection** (`crawl_wordpress_detect`)
   - Identifies WordPress sites from URL lists
   - Prepares targets for API crawling

5. **Sitemap Processing** (`crawl_sitemap_hidden`, `crawl_sitemap_non_hidden`)
   - Extracts URLs from XML sitemaps
   - Processes robots.txt files
   - Handles compressed sitemaps

6. **Delta Lake Operations** (`delta_upsert`)
   - Deduplicates crawled data
   - Merges new and existing records
   - Optimizes storage with Z-ordering

7. **Sitemap Seed Generation** (`generate_sitemap_seeds`)
   - Creates input files for next crawl iteration
   - Filters and prioritizes URLs

8. **URL Crawling** (`crawl_urls_hidden`, `crawl_urls_non_hidden`)
   - Processes URLs from sitemap seeds
   - Full page content extraction

9. **Cluster Destruction** (`cluster_destroy`)
   - Removes Karpenter resources first
   - Destroys EKS infrastructure
   - Cleans up orphaned resources

10. **S3 Cleanup** (`schedule_s3_deletion`)
    - Schedules deletion of temporary data
    - Configurable delay (default: 24 hours)
    - Verification after deletion

### 4.2 Glue Jobs

#### Delta Upsert Job
**Script**: `spark/delta_upsert.py`
**Configuration**:
- Worker Type: G.8X (8 vCPUs, 32 GB memory)
- Workers: 10
- Glue Version: 5.0 (Spark 3.3)

**Process**:
1. Read new crawl data from S3
2. Load existing Delta table
3. Merge on URL keys
4. Apply deduplication rules
5. Write optimized Delta table

#### Sitemap Generator Job
**Script**: `spark/sitemap_seed_generator.py`
**Configuration**:
- Worker Type: G.1X
- Workers: 5
- Glue Version: 5.0

**Process**:
1. Read crawled sitemap data
2. Extract and validate URLs
3. Filter by domain patterns
4. Generate seed files by domain

### 4.3 Data Flow

```
Input Seeds → Kubernetes Crawlers → S3 Raw Data → Glue Processing → Delta Tables → Next Iteration Seeds
```

**Data Formats:**
- **Input**: CSV files with URL lists
- **Raw Output**: Parquet files with crawl data
- **Processed**: Delta Lake tables
- **Schemas**: Defined in Glue Data Catalog

---

## 5. Deployment Guide

### 5.1 Prerequisites

1. **AWS Account Setup**
   - Appropriate IAM permissions
   - Service quotas for EC2, EKS
   - VPC limits for regions

2. **Tools Required**
   - Terraform >= 1.5
   - AWS CLI v2
   - kubectl
   - Python 3.11+

3. **Parameter Store Configuration**
   ```bash
   # Required parameters
   aws ssm put-parameter --name "/crawl/clusters" --value "nv,nc,ohio,oregon"
   aws ssm put-parameter --name "/s3/bucket" --value "linxact"
   aws ssm put-parameter --name "/crawl/dataset/current" --value "dataset-2409"
   aws ssm put-parameter --name "/email/admin" --value "admin@example.com"
   aws ssm put-parameter --name "/email/sender" --value "noreply@example.com"
   ```

### 5.2 Initial Setup

1. **Clone Repository**
   ```bash
   git clone https://github.com/yourorg/crawl-infrastructure
   cd crawl-infrastructure
   ```

2. **Configure Terraform Backend**
   ```bash
   cd crawl_infrastructure
   terraform init
   ```

3. **Create S3 Backend Bucket**
   ```bash
   aws s3 mb s3://your-terraform-state-bucket
   ```

### 5.3 Cluster Deployment

#### Via CodeBuild (Production)

1. **Create All Clusters**
   ```bash
   aws codebuild start-build --project-name cluster-manager \
     --environment-variables-override \
     name=ACTION,value=create \
     name=CLUSTERS,value=nv,nc,ohio,oregon
   ```

2. **Resize Specific Clusters**
   ```bash
   aws codebuild start-build --project-name cluster-manager \
     --environment-variables-override \
     name=ACTION,value=resize \
     name=CLUSTERS,value=nv,ohio \
     name=LEVEL,value=inst16
   ```

3. **Destroy Clusters**
   ```bash
   aws codebuild start-build --project-name cluster-manager \
     --environment-variables-override \
     name=ACTION,value=destroy \
     name=CLUSTERS,value=all
   ```

#### Local Development

1. **Select Workspace**
   ```bash
   terraform workspace select nv
   ```

2. **Plan Changes**
   ```bash
   terraform plan -var="instance_types=[\"t4g.medium\"]"
   ```

3. **Apply Configuration**
   ```bash
   terraform apply -auto-approve
   ```

### 5.4 Pipeline Deployment

1. **Deploy Pipeline Infrastructure**
   ```bash
   cd pipeline
   terraform init
   terraform apply
   ```

2. **Start Test Pipeline**
   ```bash
   ./scripts/start_test_pipeline.sh
   ```

3. **Start Production Pipeline**
   ```bash
   ./scripts/start_production_pipeline.sh
   ```

**TODO:** Add terraform workspace management for pipeline environments

---

## 6. Configuration Reference

### 6.1 Terraform Variables

#### Global Variables (`variables.tf`)
| Variable | Default | Description |
|----------|---------|-------------|
| `base_aws_region` | us-east-1 | Primary AWS region |
| `data_path_prefix` | update | Path prefix (update/test) |
| `s3_bucket` | linxact | S3 bucket for data |
| `dataset_base` | links/delta/dataset-2409/ | Dataset location |
| `checkpoint_table` | crawl-execution-checkpoints | DynamoDB table |

#### Cluster Variables (`crawl_infrastructure/variables.tf`)
| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | crawl-cluster | EKS cluster name |
| `cluster_version` | 1.31 | Kubernetes version |
| `vpc_cidr` | 10.0.0.0/16 | VPC CIDR block |
| `instance_types` | ["r7g.medium"] | EC2 instance types |

### 6.2 Step Functions Input

```json
{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": false,
    "cluster_create": true,
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
    "folders": ["update/seed/", "update/results/"],
    "deletion_delay_seconds": 86400,
    "check_delay_seconds": 86520
  }
}
```

### 6.3 Kubernetes Job Configuration

#### Job Template Structure
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: crawler-{timestamp}
spec:
  parallelism: 1000
  completions: null
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      containers:
      - name: crawler
        image: {ecr_repo}/crawler:latest
        resources:
          requests:
            memory: "7Gi"
            cpu: "900m"
        env:
        - name: DATASET
          value: "{dataset}"
      restartPolicy: Never
```

**TODO:** Add resource limits to prevent OOM kills

### 6.4 Environment-Specific Configurations

#### Test Environment
- Data paths: `test/seed/`, `test/results/`
- S3 deletion delay: 5 minutes
- Limited pipeline stages
- Smaller instance types

#### Production Environment
- Data paths: `update/seed/`, `update/results/`
- S3 deletion delay: 24 hours
- All pipeline stages enabled
- Production instance types

---

## 7. Monitoring and Alerting

### 7.1 Exit Code Monitor

The exit code monitor is a critical component that detects IP abuse and prevents wasted compute resources.

#### Architecture
```
Kubernetes API → Exit Code Monitor Pod → CloudWatch Metrics → Alarms → SNS → Email
                           ↓
                    Taint Nodes → Prevent New Pods
```

#### Metrics Published
- `MonitorHeartbeat`: Health check (every 5 minutes)
- `IPAbuseDetected`: Count of exit code 2 detections
- `PodsProcessed`: Pods by exit code
- `NodesTainted`: Number of tainted nodes
- `TaintedNodesPercentage`: Percentage of cluster tainted

#### Exit Code Meanings
| Code | Meaning | Action |
|------|---------|---------|
| 0 | Success | None |
| 1 | General failure | Log error |
| 2 | IP abuse detected | Taint node |
| 137 | OOM killed | Investigate memory |

### 7.2 CloudWatch Dashboards

#### Exit Code Monitor Dashboard
- Real-time pod processing metrics
- IP abuse detection trends
- Node tainting statistics
- 30-day historical data

**Access URL**: 
```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=exit-code-monitor
```

### 7.3 Alarms Configuration

| Alarm | Threshold | Period | Action |
|-------|-----------|--------|---------|
| monitor-down | < 1 heartbeat | 10 min | Email admin |
| high-ip-abuse-rate | > 10 detections | 10 min | Email admin |
| too-many-tainted-nodes | > 50% nodes | 5 min | Email admin |

### 7.4 Notification System

#### Email Recipients
- **Admin Notifications**: Critical alerts, failures
- **User Notifications**: Stage completions, summaries

#### Stage Notifications Include
- Stage name and status
- Execution time
- Resource usage
- Error details (if failed)
- Next steps

**TODO:** Add Slack/Teams webhook integration

### 7.5 Resource Monitoring

#### Lambda-based Monitors
1. **Resource Termination Verifier**
   - Checks EC2 instances are terminated
   - Verifies ENI cleanup
   - Reports orphaned resources

2. **S3 Deletion Checker**
   - Verifies scheduled deletions
   - Reports remaining objects
   - Sends confirmation emails

---

## 8. Security Analysis

### 8.1 Current Security Measures

#### Infrastructure Security
- ✅ KMS encryption for all EBS volumes
- ✅ IMDSv2 enforced on all instances
- ✅ Private subnets for worker nodes
- ✅ Security groups with minimal ingress
- ✅ IAM roles with least privilege
- ✅ OIDC provider for service accounts

#### Data Security
- ✅ S3 bucket encryption
- ✅ Parameter Store for secrets
- ✅ TLS for all API communications
- ✅ Delta Lake ACID transactions

### 8.2 Identified Vulnerabilities

#### High Priority
1. **Missing Resource Limits**
   ```yaml
   # Current (vulnerable)
   resources:
     requests:
       memory: "7Gi"
   
   # Recommended
   resources:
     requests:
       memory: "7Gi"
       cpu: "900m"
     limits:
       memory: "8Gi"
       cpu: "1000m"
   ```

2. **Credentials in Pod Specs**
   - AWS credentials visible in environment variables
   - Should use IRSA or Kubernetes secrets

3. **No Network Policies**
   - Pods can communicate freely
   - Should implement zero-trust networking

#### Medium Priority
1. **DNS Configuration**
   - Bypasses cluster DNS
   - Could miss internal service discovery

2. **Short TTL for Failed Jobs**
   - 5 minutes insufficient for debugging
   - Recommend 1-2 hours for failed jobs

3. **No Pod Disruption Budgets**
   - Spot instances can cause mass disruptions
   - Need PDBs for graceful handling

### 8.3 Security Recommendations

1. **Implement Pod Security Standards**
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: crawlers
     labels:
       pod-security.kubernetes.io/enforce: restricted
       pod-security.kubernetes.io/audit: restricted
       pod-security.kubernetes.io/warn: restricted
   ```

2. **Add Network Policies**
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: crawler-network-policy
   spec:
     podSelector:
       matchLabels:
         app: crawler
     policyTypes:
     - Ingress
     - Egress
     egress:
     - to:
       - namespaceSelector: {}
       ports:
       - protocol: TCP
         port: 443
       - protocol: TCP
         port: 80
       - protocol: UDP
         port: 53
   ```

3. **Enable Audit Logging**
   - Configure EKS audit logs
   - Ship to CloudWatch Logs
   - Set up anomaly detection

**TODO:** Implement comprehensive security scanning pipeline

---

## 9. Cost Optimization

### 9.1 Current Optimizations

#### Compute
- ✅ ARM64 instances (40% cheaper)
- ✅ Spot instances for workers
- ✅ Automatic cluster destruction
- ✅ Karpenter consolidation
- ✅ Right-sized instance types

#### Storage
- ✅ S3 lifecycle policies
- ✅ Scheduled deletion of temp data
- ✅ Delta Lake compression
- ✅ Intelligent tiering

#### Network
- ✅ VPC endpoints for S3/DynamoDB
- ✅ Regional deployments
- ✅ Minimal cross-AZ traffic

### 9.2 Cost Breakdown (Estimated Monthly)

| Component | Cost | Notes |
|-----------|------|-------|
| EKS Control Plane | $292 | $0.10/hour × 4 clusters |
| EC2 Instances | $500-2000 | Varies with workload |
| NAT Gateways | $180 | $0.045/hour × 4 |
| S3 Storage | $100-500 | Depends on data volume |
| Glue Jobs | $200-800 | Based on DPU hours |
| Data Transfer | $50-200 | Mostly regional |
| **Total** | **$1,322-3,972** | Per month estimate |

### 9.3 Optimization Opportunities

1. **Use S3 Gateway Endpoints**
   - Eliminate data transfer costs
   - Already implemented ✅

2. **Implement Cluster Scheduling**
   - Run clusters only during business hours
   - Potential 70% compute savings

3. **Data Lifecycle Management**
   - Move old data to Glacier
   - Delete redundant datasets

4. **Reserved Capacity**
   - Purchase RIs for predictable workloads
   - Consider Savings Plans

**TODO:** Implement cost allocation tags for detailed tracking

---

## 10. Troubleshooting Guide

### 10.1 Common Issues

#### Cluster Creation Failures

**Symptom**: Terraform fails with subnet/VPC errors
```
Error: creating EKS Cluster: InvalidParameterException: Subnets specified must be in at least 2 different availability zones
```

**Solution**:
1. Check VPC has subnets in multiple AZs
2. Verify subnet tags are correct
3. Ensure VPC CIDR doesn't conflict

#### Karpenter Not Scaling

**Symptom**: Pods stuck in Pending state

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
kubectl logs -n karpenter karpenter
```

**Common Causes**:
- Instance type not available in AZ
- Subnet capacity exhausted
- IAM permissions missing

#### IP Abuse Detection Issues

**Symptom**: Nodes being tainted unnecessarily

**Check**:
```bash
# View tainted nodes
kubectl get nodes -o json | jq '.items[] | select(.spec.taints) | .metadata.name'

# Check exit code monitor logs
kubectl logs -n monitoring exit-code-monitor
```

**Resolution**:
- Verify exit code detection logic
- Check for transient network issues
- Review crawler retry logic

### 10.2 Debugging Tools

#### Cluster Health Check
```bash
#!/bin/bash
# check_cluster_health.sh

echo "=== Cluster Info ==="
kubectl cluster-info

echo "=== Node Status ==="
kubectl get nodes

echo "=== Karpenter Nodepools ==="
kubectl get nodepools

echo "=== Running Pods ==="
kubectl get pods --all-namespaces | grep -E "(crawler|monitor)"

echo "=== Recent Events ==="
kubectl get events --sort-by='.lastTimestamp' | tail -20
```

#### Job Debugging
```bash
# Get job details
kubectl describe job <job-name>

# View pod logs
kubectl logs -l job-name=<job-name> --tail=100

# Check exit codes
kubectl get pods -l job-name=<job-name> -o json | \
  jq '.items[].status.containerStatuses[].state.terminated.exitCode'
```

### 10.3 Performance Tuning

#### Crawler Performance
1. **Adjust Parallelism**
   ```yaml
   parallelism: 2000  # Increase for faster processing
   ```

2. **Memory Allocation**
   - Monitor actual usage
   - Adjust requests/limits accordingly

3. **Network Optimization**
   - Use larger instance types for network-intensive workloads
   - Consider placement groups

#### Glue Job Optimization
1. **Increase DPU Allocation**
   ```python
   # In Terraform
   number_of_workers = 20  # Default: 10
   ```

2. **Partition Strategy**
   - Partition by date/domain
   - Use Z-ordering for queries

**TODO:** Add automated performance profiling

---

## 11. Development Guidelines

### 11.1 Code Organization

```
crawl-infrastructure/
├── cluster_manager.py          # Main orchestrator
├── crawl_infrastructure/       # Terraform for EKS
│   ├── main.tf                # Cluster resources
│   ├── variables.tf           # Input variables
│   ├── outputs.tf             # Output values
│   └── karpenter/             # Karpenter configs
├── pipeline/                   # Step Functions pipeline
│   ├── main.tf                # Pipeline definition
│   ├── lambdas/               # Lambda functions
│   ├── scripts/               # Helper scripts
│   └── glue-scripts/          # Spark jobs
└── kube_job.py                # Job management
```

### 11.2 Development Workflow

1. **Feature Branch**
   ```bash
   git checkout -b feature/your-feature
   ```

2. **Local Testing**
   - Use terraform plan
   - Test with small datasets
   - Validate in test environment

3. **Code Review**
   - Create pull request
   - Require approval from team lead
   - Run automated tests

4. **Deployment**
   - Merge to main
   - CodeBuild auto-deploys
   - Monitor for issues

### 11.3 Coding Standards

#### Python
- Use Python 3.11+
- Follow PEP 8
- Type hints required
- Docstrings for all functions

```python
def process_crawl_data(
    input_path: str,
    output_path: str,
    dedup_columns: List[str]
) -> Dict[str, Any]:
    """
    Process crawl data with deduplication.
    
    Args:
        input_path: S3 path to input data
        output_path: S3 path for output
        dedup_columns: Columns for deduplication
        
    Returns:
        Dictionary with processing metrics
    """
```

#### Terraform
- Use consistent formatting
- Pin provider versions
- Meaningful resource names
- Comments for complex logic

```hcl
# Create VPC endpoints to reduce data transfer costs
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.region}.s3"
  
  tags = {
    Name        = "${var.cluster_name}-s3-endpoint"
    Environment = var.environment
  }
}
```

### 11.4 Testing Strategy

#### Unit Tests
- Test Lambda functions locally
- Mock AWS services
- Validate business logic

#### Integration Tests
- Deploy to test environment
- Run small-scale crawls
- Verify data processing

#### Load Tests
- Gradually increase scale
- Monitor resource usage
- Identify bottlenecks

**TODO:** Implement automated testing pipeline

---

## 12. TODOs and Recommendations

### 12.1 High Priority TODOs

1. **Security Hardening**
   - [ ] Add resource limits to all containers
   - [ ] Implement pod security policies
   - [ ] Add network policies
   - [ ] Enable audit logging
   - [ ] Rotate credentials to use Secrets

2. **Reliability Improvements**
   - [ ] Add pod disruption budgets
   - [ ] Implement job retry logic
   - [ ] Add circuit breakers
   - [ ] Create disaster recovery plan
   - [ ] Add health check endpoints

3. **Monitoring Enhancements**
   - [ ] Deploy Prometheus/Grafana
   - [ ] Add custom metrics
   - [ ] Create SLO dashboards
   - [ ] Implement distributed tracing
   - [ ] Add log aggregation

### 12.2 Medium Priority TODOs

1. **Performance Optimization**
   - [ ] Implement job checkpointing
   - [ ] Add work-stealing queue
   - [ ] Optimize Delta Lake merges
   - [ ] Add caching layer
   - [ ] Profile and optimize crawlers

2. **Operational Improvements**
   - [ ] Create runbooks for common issues
   - [ ] Add automated remediation
   - [ ] Implement GitOps workflow
   - [ ] Add configuration validation
   - [ ] Create backup strategies

3. **Cost Optimization**
   - [ ] Implement cluster scheduling
   - [ ] Add spot instance interruption handling
   - [ ] Create cost allocation reports
   - [ ] Optimize data retention
   - [ ] Review instance sizing

### 12.3 Long-term Recommendations

1. **Architecture Evolution**
   - Migrate to Kubernetes native jobs
   - Implement service mesh
   - Add multi-region failover
   - Create API gateway
   - Implement event-driven architecture

2. **Platform Capabilities**
   - Add web UI for monitoring
   - Create self-service portal
   - Implement RBAC
   - Add audit trails
   - Create data catalog

3. **Advanced Features**
   - Machine learning for URL prioritization
   - Intelligent rate limiting
   - Content change detection
   - Automated quality checks
   - Real-time streaming processing

### 12.4 Quick Wins

1. **Increase TTL for failed jobs** (5 min → 2 hours)
   ```yaml
   ttlSecondsAfterFinished: 7200  # 2 hours for debugging
   ```

2. **Add resource limits**
   ```yaml
   resources:
     limits:
       memory: "8Gi"
       cpu: "1000m"
   ```

3. **Enable cluster autoscaler metrics**
   ```yaml
   metrics:
     - type: Resource
       resource:
         name: memory
         target:
           type: Utilization
           averageUtilization: 80
   ```

4. **Add job labels for tracking**
   ```yaml
   labels:
     crawl-type: "wordpress-api"
     dataset: "2409"
     region: "us-east-1"
   ```

---

## Appendix A: Command Reference

### Cluster Management
```bash
# Create clusters
./cluster_manager.py --action create --clusters nv,nc

# Resize clusters
./cluster_manager.py --action resize --clusters nv --level inst16

# Destroy clusters
./cluster_manager.py --action destroy --clusters all
```

### Pipeline Operations
```bash
# Start test pipeline
./pipeline/scripts/start_test_pipeline.sh

# Start production pipeline
./pipeline/scripts/start_production_pipeline.sh

# Check pipeline status
aws stepfunctions describe-execution \
  --execution-arn arn:aws:states:region:account:execution:name
```

### Kubernetes Management
```bash
# Update kubeconfig
aws eks update-kubeconfig --name crawl-cluster-nv --region us-east-1

# Deploy job
python kube_job.py --input seeds.csv --dataset dataset-2409

# Check job status
kubectl get jobs -l dataset=dataset-2409
```

---

## Appendix B: Architecture Diagrams

### Data Flow Diagram
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Input     │     │  Crawlers   │     │   Output    │
│   Seeds     │────▶│    (K8s)    │────▶│  (Parquet)  │
└─────────────┘     └─────────────┘     └─────────────┘
                           │                     │
                           ▼                     ▼
                    ┌─────────────┐     ┌─────────────┐
                    │ Exit Code   │     │    Glue     │
                    │  Monitor    │     │    Jobs     │
                    └─────────────┘     └─────────────┘
                           │                     │
                           ▼                     ▼
                    ┌─────────────┐     ┌─────────────┐
                    │  CloudWatch │     │ Delta Lake  │
                    │   Metrics   │     │   Tables    │
                    └─────────────┘     └─────────────┘
```

### Network Architecture
```
┌─────────────────────────────────────────────────┐
│                    VPC (10.0.0.0/16)            │
├─────────────────────┬───────────────────────────┤
│   Public Subnets    │    Private Subnets        │
│  ┌──────────────┐   │   ┌──────────────┐       │
│  │ NAT Gateway  │   │   │ EKS Nodes    │       │
│  │ ALB          │   │   │ Karpenter    │       │
│  └──────────────┘   │   └──────────────┘       │
│                     │                           │
│  ┌──────────────┐   │   ┌──────────────┐       │
│  │ VPC Endpoints│   │   │ RDS/DynamoDB │       │
│  │ (S3, EC2)   │   │   │              │       │
│  └──────────────┘   │   └──────────────┘       │
└─────────────────────┴───────────────────────────┘
```

---

## Document Information

**Version**: 1.0.0  
**Last Updated**: December 2024  
**Author**: AI Assistant  
**Review Status**: Draft  

**Note**: This documentation is comprehensive but should be reviewed and updated regularly as the system evolves. All TODO items should be tracked in your project management system.

---