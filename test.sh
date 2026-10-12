#!/bin/bash
# POST a record through the IAM-authorized API and check that it reaches S3
# through DynamoDB -> Kinesis -> Firehose, transformed by the Lambda function
# into plain JSON.
set -euo pipefail

STACK=AwsDynamodbKinesisfirehoseS3IngestionStack
MAX_ATTEMPTS=${MAX_ATTEMPTS:-60}
DATA="ci-$(date +%s)"

API_URL=$(lstk aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?starts_with(OutputKey, 'SourceDataRestApiEndpoint')].OutputValue | [0]" --output text)
STREAM=$(lstk aws cloudformation list-stack-resources --stack-name "$STACK" \
  --query "StackResourceSummaries[?ResourceType=='AWS::KinesisFirehose::DeliveryStream'].PhysicalResourceId | [0]" --output text)
BUCKET=$(lstk aws firehose describe-delivery-stream --delivery-stream-name "$STREAM" \
  --query 'DeliveryStreamDescription.Destinations[0].ExtendedS3DestinationDescription.BucketARN' --output text)
BUCKET=${BUCKET#arn:aws:s3:::}
echo "API: $API_URL"
echo "Bucket: $BUCKET"

# The API uses IAM authorization, so requests are SigV4-signed
api() {
  curl -sk --fail-with-body --aws-sigv4 "aws:amz:${AWS_DEFAULT_REGION:-us-east-1}:execute-api" \
    --user "${AWS_ACCESS_KEY_ID:-test}:${AWS_SECRET_ACCESS_KEY:-test}" "$@"
}

echo "Posting record with data $DATA"
api -X POST "$API_URL" -H 'Content-Type: application/json' -d "{\"data\":\"$DATA\"}" > /dev/null

TABLE=$(lstk aws cloudformation list-stack-resources --stack-name "$STACK" \
  --query "StackResourceSummaries[?ResourceType=='AWS::DynamoDB::Table'].PhysicalResourceId | [0]" --output text)
ID=$(lstk aws dynamodb scan --table-name "$TABLE" \
  --filter-expression 'MessageData = :d' --expression-attribute-values "{\":d\":{\"S\":\"$DATA\"}}" \
  --query 'Items[0].SourceDataId.S' --output text)
if [ -z "$ID" ] || [ "$ID" = "None" ]; then
  echo "Test failed: record was not written to DynamoDB table $TABLE"
  exit 1
fi
echo "PASS: record stored in DynamoDB with id $ID"

if ! api "${API_URL%/}/$ID" | jq -e --arg d "$DATA" '.Items[0].MessageData.S == $d' > /dev/null; then
  echo "Test failed: GET /$ID did not return the record"
  exit 1
fi
echo "PASS: record readable through the API"

# Firehose writes the transformed record (plain JSON, not a DynamoDB stream
# record) to the bucket
delivered=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  for key in $(lstk aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output text); do
    [ "$key" = "None" ] && continue
    delivered=$(lstk aws s3 cp "s3://$BUCKET/$key" - | jq -c --arg d "$DATA" 'select(.MessageData == $d)' 2>/dev/null || true)
    [ -n "$delivered" ] && break 2
  done
  echo "Attempt $attempt/$MAX_ATTEMPTS: record not in S3 yet"
  sleep 5
done

if [ -z "$delivered" ]; then
  echo "Test failed: record did not reach S3"
  exit 1
fi
if ! echo "$delivered" | jq -e --arg id "$ID" '.SourceDataId == $id' > /dev/null; then
  echo "Test failed: unexpected record in S3: $delivered"
  exit 1
fi
echo "PASS: transformed record delivered to S3: $delivered"

echo "Test passed: record flowed from the API to S3"
