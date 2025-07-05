#!/bin/bash
# Setup script for creating the /email/sender SSM parameter

echo "Setting up /email/sender SSM parameter..."

# Check if the parameter already exists
if aws ssm get-parameter --name /email/sender >/dev/null 2>&1; then
    echo "Parameter /email/sender already exists."
    read -p "Do you want to update it? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting without changes."
        exit 0
    fi
fi

# Get current admin email as default
CURRENT_ADMIN=$(aws ssm get-parameter --name /email/admin --query 'Parameter.Value' --output text 2>/dev/null)

if [ -z "$CURRENT_ADMIN" ]; then
    echo "Warning: Could not fetch current admin email from /email/admin"
    DEFAULT_SENDER=""
else
    DEFAULT_SENDER="$CURRENT_ADMIN"
    echo "Current admin email: $DEFAULT_SENDER"
fi

# Prompt for sender email
read -p "Enter sender email address [default: $DEFAULT_SENDER]: " SENDER_EMAIL
SENDER_EMAIL=${SENDER_EMAIL:-$DEFAULT_SENDER}

if [ -z "$SENDER_EMAIL" ]; then
    echo "Error: Sender email cannot be empty"
    exit 1
fi

# Validate email format (basic check)
if ! [[ "$SENDER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: Invalid email format"
    exit 1
fi

# Create or update the parameter
echo "Setting /email/sender to: $SENDER_EMAIL"
if aws ssm put-parameter --name /email/sender --value "$SENDER_EMAIL" --type String --overwrite; then
    echo "✅ Successfully set /email/sender parameter"
    echo
    echo "⚠️  Important: Make sure this email is verified in AWS SES!"
    echo "To verify: aws ses verify-email-identity --email-address $SENDER_EMAIL"
    echo
    echo "Next steps:"
    echo "1. Run 'terraform apply' to update IAM policies"
    echo "2. The new sender email will be used immediately for all notifications"
else
    echo "❌ Failed to set parameter"
    exit 1
fi