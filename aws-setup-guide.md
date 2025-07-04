# AWS Configuration Guide

## Option 1: Interactive Configuration

Run this command in your terminal:
```bash
aws configure
```

You will be prompted for:
1. **AWS Access Key ID**: Your access key (starts with AKIA...)
2. **AWS Secret Access Key**: Your secret key
3. **Default region name**: us-east-1 (or your preferred region)
4. **Default output format**: json (recommended)

## Option 2: Configure with Environment Variables

Add these to your shell profile (~/.zshrc or ~/.bash_profile):
```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_DEFAULT_REGION="us-east-1"
```

Then reload your shell:
```bash
source ~/.zshrc
```

## Option 3: Configure Specific Profile

If you have multiple AWS accounts:
```bash
aws configure --profile crawl-infrastructure
```

Then use it with:
```bash
export AWS_PROFILE=crawl-infrastructure
```

## Option 4: Use AWS SSO (if your organization uses it)

```bash
aws configure sso
```

Follow the prompts to set up SSO access.

## Verify Configuration

After configuring, verify it works:
```bash
aws sts get-caller-identity
```

This should show your AWS account ID and user information.

## Security Best Practices

1. **Never commit credentials** to git
2. **Use IAM roles** when running on EC2
3. **Rotate access keys** regularly
4. **Use MFA** when possible
5. **Consider using AWS SSO** for better security

## For Your Infrastructure

Based on your setup, you'll need permissions to:
- Manage IAM policies and roles
- Access S3 (terraform state)
- Access DynamoDB (terraform locks)
- Manage CodeBuild projects

The user/role you use should have these permissions to apply the Terraform changes.