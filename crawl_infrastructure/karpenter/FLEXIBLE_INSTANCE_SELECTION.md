# Karpenter Flexible Instance Selection Guide

## Overview

This guide explains how to configure Karpenter for automatic instance selection based on pod requirements rather than hardcoding specific instance types.

## Benefits of Flexible Instance Selection

1. **Cost Optimization**: Karpenter automatically selects the most cost-effective instances
2. **Better Availability**: Access to a wider range of instance pools reduces interruption risk
3. **Future-Proof**: Automatically use newer instance generations as they become available
4. **Dynamic Scaling**: Adapts to changing capacity constraints in real-time

## Configuration Changes

### 1. NodePool Requirements

Instead of specifying exact instance types, use instance categories and constraints:

```yaml
requirements:
  # Capacity type (spot/on-demand)
  - key: "karpenter.sh/capacity-type"
    operator: In
    values: ["spot"]
  
  # Instance categories (c=compute, m=general, r=memory, t=burstable)
  - key: "karpenter.k8s.aws/instance-category"
    operator: In
    values: ["m", "r", "t", "c"]
  
  # Instance generation (6th gen and newer)
  - key: "karpenter.k8s.aws/instance-generation"
    operator: Gt
    values: ["5"]
  
  # Architecture
  - key: "kubernetes.io/arch"
    operator: In
    values: ["arm64"]
```

### 2. Optional Constraints

You can optionally specify:
- **Instance Families**: Specific families like `["r7g", "r6g", "m7g"]`
- **Instance Sizes**: Size constraints like `["medium", "large", "xlarge"]`

### 3. EC2NodeClass Configuration

Set `maxPods` to 110 (AWS EKS default) to let Karpenter calculate based on ENI limits:

```yaml
spec:
  kubelet:
    maxPods: 110
```

## Usage Examples

### Minimal Configuration (Maximum Flexibility)

```json
{
  "karpenter_provisioner": {
    "name": "default",
    "architectures": ["arm64"],
    "topology": ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}
```

### With Instance Family Constraints

```json
{
  "karpenter_provisioner": {
    "name": "default",
    "architectures": ["arm64"],
    "instance-families": ["r7g", "r6g", "m7g", "m6g"],
    "instance-sizes": ["medium", "large"],
    "topology": ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}
```

### Legacy Mode (Specific Instance Types)

```json
{
  "karpenter_provisioner": {
    "name": "default",
    "architectures": ["arm64"],
    "instance-type": ["r7g.medium", "r6g.medium"],
    "topology": ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}
```

## How Karpenter Selects Instances

1. **Pod Requirements Analysis**: Karpenter analyzes pod resource requests and node selectors
2. **Instance Filtering**: Filters available instances based on NodePool requirements
3. **Cost Optimization**: Selects the most cost-effective instances that meet requirements
4. **EC2 Fleet API**: Passes instance list to EC2 Fleet for final selection

## Best Practices

1. **Use Instance Categories**: Prefer categories over specific types for flexibility
2. **Set Generation Constraints**: Use newer generations (6+) for better performance/cost
3. **ARM64 Architecture**: Stick with ARM64 for cost optimization
4. **Avoid Over-Constraining**: More flexibility = better availability and cost
5. **Monitor Instance Selection**: Use Karpenter metrics to understand selection patterns

## Migration Steps

1. Update NodePool template to use flexible requirements
2. Update EC2NodeClass maxPods to 110
3. Update Terraform variables to support optional parameters
4. Test with a small workload before full rollout
5. Monitor costs and performance after migration

## Troubleshooting

- **No instances launched**: Check if requirements are too restrictive
- **Wrong instance types**: Verify instance category and generation requirements
- **High costs**: Consider adding size constraints or adjusting categories
- **Interruptions**: Ensure sufficient instance diversity for spot instances