# EmailSentinel

## Project Structure

- **main.py**: Main script for the project.
- **Makefile**: Contains build and management commands.
- **requirements.txt**: Lists the project's dependencies.
- **scripts/**: Directory containing utility scripts.
  - **check_results.py**: Script to check results.
  - **send_test_email.py**: Script to send test emails.
- **terraform/**: Directory containing Terraform configuration files.
  - **.terraform.lock.hcl**: Terraform lock file.
  - **main.tf**: Main Terraform configuration file.
  - **terraform.tfstate**: Terraform state file.

## Setup

1. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

2. Run the main script:
   ```bash
   python main.py
   ```

## How It Works

EmailSentinel is designed to automate email testing and infrastructure management.
The main script (`main.py`) orchestrates the process, utilizing utility scripts and Terraform configurations.

### Email Verification Process

1. **Syntax Validation**: Checks if the email follows a valid syntax.
2. **Disposable Email Check**: Identifies if the email is from a disposable email provider.
3. **Role-Based Email Check**: Flags role-based emails (e.g., admin, support).
4. **MX Record Check**: Retrieves MX records for the email domain.
5. **SMTP Connection Check**: Verifies if the SMTP server is reachable.
6. **SMTP Handshake**: Performs an SMTP handshake to verify the email.
7. **Catch All Detection**: Checks if the domain is a catch-all email provider.

### Input Sources

- **SQSInputSource**: Fetches emails from an AWS SQS queue.
- **FileInputSource**: Fetches emails from a local file.

### Storage Backends

- **DynamoDBStorage**: Stores email verification results in AWS DynamoDB.
- **FileStorage**: Stores email verification results in a local JSON file.

## Makefile Targets

- **help**: Display help menu.
- **deploy**: Deploy infrastructure and update Lambda function.
- **destroy**: Destroy AWS infrastructure.
- **logs**: Tail Lambda logs in real-time.
- **queue-status**: Check the number of messages in the SQS queue.
- **send-test-emails**: Send test emails to the queue.
- **check-results**: Check verification results from DynamoDB.
- **package-lambda**: Package the Lambda function.
- **update-lambda**: Update Lambda function code.
- **run-local**: Run script locally as Docker container.
