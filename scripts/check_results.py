import argparse
import boto3
from botocore.exceptions import ClientError

def check_emails(table_name, emails_to_check):
    """Check email verification results in DynamoDB."""
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    table = dynamodb.Table(table_name)

    try:
        # Verify table exists
        table.load()
    except ClientError as e:
        print(f"Error: Could not access table '{table_name}': {e}")
        return

    for email in emails_to_check:
        try:
            response = table.get_item(Key={'email': email})
            if 'Item' in response:
                print(f"{email}: {response['Item']}")
            else:
                print(f"{email} not found in the results.")
        except ClientError as e:
            print(f"Error checking {email}: {e}")

def main():
    parser = argparse.ArgumentParser(description="Check email verification results in DynamoDB.")
    parser.add_argument("--table-name", required=True, help="The name of the DynamoDB table")
    args = parser.parse_args()

    emails_to_check = [
            "test@example.com",
            "invalid@nonexistent.com"
    ]

    check_emails(args.table_name, emails_to_check)

if __name__ == "__main__":
    main()
