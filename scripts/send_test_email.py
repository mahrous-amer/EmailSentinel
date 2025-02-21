import argparse
import boto3
from botocore.exceptions import ClientError

def send_test_emails(queue_url, test_emails):
    """Send test emails to an SQS queue."""
    sqs = boto3.client('sqs', region_name='us-east-1')

    try:
        # Verify queue exists by getting its attributes
        sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=['QueueArn'])
    except ClientError as e:
        print(f"Error: Could not access queue '{queue_url}': {e}")
        return

    # Send each email to the queue
    sent_count = 0
    for email in test_emails:
        try:
            sqs.send_message(QueueUrl=queue_url, MessageBody=email)
            sent_count += 1
        except ClientError as e:
            print(f"Error sending {email} to queue: {e}")
        except ValueError as e:
            print(f"Invalid email format for {email}: {e}")

    if sent_count > 0:
        print(f"Sent {sent_count} emails to the queue.")
    else:
        print("No emails sent successfully.")

def main():
    parser = argparse.ArgumentParser(description="Send test emails to an SQS queue.")
    parser.add_argument("--queue-url", required=True, help="The URL of the SQS queue")
    args = parser.parse_args()

    test_emails = [
            "test@example.com",
            "invalid@nonexistent.com"
    ]

    send_test_emails(args.queue_url, test_emails)

if __name__ == "__main__":
    main()
