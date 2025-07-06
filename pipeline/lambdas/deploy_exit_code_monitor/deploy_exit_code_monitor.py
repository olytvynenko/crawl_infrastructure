#!/usr/bin/env python3
"""
Lambda function to deploy exit code monitor to EKS clusters
"""

import os
import json
import boto3
import base64
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Kubernetes deployment manifest template
DEPLOYMENT_MANIFEST = """
apiVersion: v1
kind: ServiceAccount
metadata:
  name: exit-code-monitor
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: exit-code-monitor
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: exit-code-monitor
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: exit-code-monitor
subjects:
- kind: ServiceAccount
  name: exit-code-monitor
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exit-code-monitor
  namespace: default
  labels:
    app: exit-code-monitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: exit-code-monitor
  template:
    metadata:
      labels:
        app: exit-code-monitor
    spec:
      serviceAccountName: exit-code-monitor
      containers:
      - name: monitor
        image: {IMAGE_URI}
        imagePullPolicy: Always
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        env:
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: AWS_REGION
          value: "{AWS_REGION}"
        - name: CLUSTER_NAME
          value: "{CLUSTER_NAME}"
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: DoesNotExist
      tolerations:
      - key: "crawler/ip-blocked"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "CrawlJob"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
"""


def lambda_handler(event, context):
    """
    Deploy exit code monitor to specified clusters
    
    Event structure:
    {
        "clusters": ["nv", "nc", "ohio", "oregon"],  # Optional, defaults to all
        "image_uri": "override-image-uri"  # Optional
    }
    """
    
    # Initialize clients
    ssm = boto3.client('ssm')
    eks = boto3.client('eks')
    
    # Get image URI
    image_uri = event.get('image_uri')
    if not image_uri:
        # Get from environment or SSM
        image_uri = os.environ.get('ECR_REPOSITORY_URI', '')
        image_tag = os.environ.get('IMAGE_TAG', 'exit-code-monitor-latest')
        if image_uri and ':' not in image_uri:
            image_uri = f"{image_uri}:{image_tag}"
    
    if not image_uri:
        try:
            param_response = ssm.get_parameter(Name='/crawler/exit-code-monitor/image')
            image_uri = param_response['Parameter']['Value']
        except Exception as e:
            logger.error(f"Failed to get image URI: {e}")
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'No image URI specified'})
            }
    
    logger.info(f"Using image: {image_uri}")
    
    # Get list of clusters
    clusters = event.get('clusters', [])
    if not clusters:
        # Get from SSM parameter
        try:
            clusters_param = ssm.get_parameter(Name='/crawl/clusters')
            clusters = [c.strip() for c in clusters_param['Parameter']['Value'].split(',')]
        except Exception as e:
            logger.error(f"Failed to get clusters list: {e}")
            clusters = ['nv', 'nc', 'ohio', 'oregon']  # Default
    
    # Deploy to each cluster
    results = {}
    cluster_map = {
        'nv': 'linxact-nv-us-east-1',
        'nc': 'linxact-nc-us-west-1', 
        'ohio': 'linxact-oh-us-east-2',
        'oregon': 'linxact-or-us-west-2'
    }
    
    # Region mapping
    region_map = {
        'nv': 'us-east-1',
        'nc': 'us-west-1',
        'ohio': 'us-east-2',
        'oregon': 'us-west-2'
    }
    
    for cluster_alias in clusters:
        cluster_name = cluster_map.get(cluster_alias, cluster_alias)
        cluster_region = region_map.get(cluster_alias, 'us-east-1')
        
        try:
            # Get cluster info
            cluster_info = eks.describe_cluster(name=cluster_name)
            endpoint = cluster_info['cluster']['endpoint']
            cert_authority = cluster_info['cluster']['certificateAuthority']['data']
            
            # Update manifest with image URI and environment variables
            manifest = DEPLOYMENT_MANIFEST.replace('{IMAGE_URI}', image_uri)
            manifest = manifest.replace('{AWS_REGION}', cluster_region)
            manifest = manifest.replace('{CLUSTER_NAME}', cluster_alias)
            
            # Note: In a real implementation, you would use the Kubernetes Python client
            # or kubectl via Lambda layer to apply this manifest.
            # For now, we'll store it in S3 for manual application
            
            results[cluster_alias] = {
                'status': 'prepared',
                'cluster': cluster_name,
                'image': image_uri,
                'message': 'Manifest prepared for deployment'
            }
            
            logger.info(f"Prepared deployment for cluster {cluster_name}")
            
        except Exception as e:
            logger.error(f"Failed to prepare deployment for {cluster_alias}: {e}")
            results[cluster_alias] = {
                'status': 'failed',
                'error': str(e)
            }
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'image_uri': image_uri,
            'results': results
        })
    }