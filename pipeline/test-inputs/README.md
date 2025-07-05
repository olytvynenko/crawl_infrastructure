# Test Inputs for Step Functions Pipeline

This directory contains test and example input files for the Step Functions pipeline.

## Files

### General Examples
- `step-functions-input-examples.json` - Various examples of pipeline input configurations

### S3 Deletion Testing
- `test-s3-deletion-input.json` - Test input for S3 deletion with 5-minute deletion and 7-minute check
- `test-s3-deletion-disabled-input.json` - Test showing how to disable S3 deletion via input parameter
- `test-s3-scheduling-notification.json` - Test input to verify scheduling notification works
- `s3-deletion-relative-paths-example.json` - Examples of relative path configurations
- `s3-deletion-time-examples.json` - Examples of different time delay configurations

### Notification Testing
- `test-notification.json` - Test input for notification system
- `test-notification-error.json` - Test input for error notification scenarios

## Usage

To test the pipeline with any of these inputs:

```bash
# Start a Step Functions execution with a test input
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:ACCOUNT_ID:stateMachine:crawl-pipeline \
  --input file://test-inputs/test-s3-deletion-input.json
```

## Templates

The main input templates are located in the parent directory:
- `../step-functions-input-template.json` - Basic template without comments
- `../step-functions-input-template-with-comments.json` - Detailed template with inline documentation