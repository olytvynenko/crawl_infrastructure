# Karpenter Installation Fixes

## Problems
The installation was failing with multiple access entry conflicts:

1. **Karpenter Node Access Entry**:
```
Error: creating EKS Access Entry (linxact-nv:arn:aws:iam::411623750878:role/crawl-admin-eks-node-group-20250708082916504100000003): 
ResourceInUseException: The specified access entry resource is already in use on this cluster.
```

2. **Console User Access Entry**:
```
Error: creating EKS Access Entry (linxact-nv:arn:aws:iam::411623750878:user/olexiy): 
ResourceInUseException: The specified access entry resource is already in use on this cluster.
```

These occurred because:
- The managed node group already creates its own access entry
- The console user access entry might already exist from previous runs

## Changes Made

### 1. Created Dedicated IAM Role for Karpenter Nodes
- Set `create_node_iam_role = true` in karpenter.tf
- Removed reuse of managed node group role
- Updated EC2NodeClass to auto-discover the Karpenter-managed role
- **Important**: Set `create_access_entry = false` to prevent conflicts

### 2. Fixed Taint Effect Casing
- Changed from `NoSchedule`/`NoExecute` to `NO_SCHEDULE`/`NO_EXECUTE`
- Ensures consistency with EKS managed node group taints

### 3. Added OIDC Provider Readiness Check
- Added 30-second wait before Helm installation
- Ensures OIDC provider is fully propagated in AWS

### 4. Removed Pod Identity Association
- Set `create_pod_identity_association = false`
- Not needed for current configuration

### 5. Added Cleanup Hooks
- Implemented proper NodePool and EC2NodeClass deletion on destroy
- Includes 30-second wait for node termination

### 6. Fixed Console User Access Entry Conflict
- Added import block in auth.tf to handle existing access entries
- Added lifecycle rule to prevent recreation

## Files Modified
1. `/crawl_infrastructure/karpenter/karpenter.tf`
2. `/crawl_infrastructure/karpenter/configs/karpenter-ec2nodeclass.yaml.tmpl`
3. `/crawl_infrastructure/auth.tf`

## Next Steps
Run the deployment again with:
```bash
terraform -chdir=crawl_infrastructure apply -target module.karpenter
```

The changes ensure Karpenter uses its own dedicated IAM role and avoids conflicts with the managed node group's access entry.