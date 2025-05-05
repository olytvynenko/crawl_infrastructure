# Kick off a CodeBuild build for “cluster-manager”

# --no-cli-pager                 : print the JSON response directly

# --environment-variables-override:

# ACTION = create → cluster_manager.py will CREATE resources

# CLUSTERS = nv → target the “nv” workspace only

aws --no-cli-pager codebuild start-build --project-name cluster-manager --environment-variables-override
name=ACTION,value=create name=CLUSTERS,value=nv

# Run the same project but let cluster_manager.py APPLY any pending changes

# (equivalent to ‘terraform apply’ inside the helper)

aws --no-cli-pager codebuild start-build --project-name cluster-manager --environment-variables-override
name=ACTION,value=apply name=CLUSTERS,value=nv

# Destroy the resources in the “nv” workspace

# WARNING: this will remove the cluster and associated AWS assets

aws --no-cli-pager codebuild start-build --project-name cluster-manager --environment-variables-override
name=ACTION,value=destroy name=CLUSTERS,value=nv
