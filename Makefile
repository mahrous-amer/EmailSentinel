SHELL := /bin/bash

# AWS Variables
SQS_QUEUE_URL ?= $(shell terraform output -raw sqs_queue_url 2>/dev/null || echo "$${SQS_QUEUE_URL}")
LAMBDA_FUNCTION_NAME ?= emailVerifier
DYNAMODB_TABLE_NAME ?= email_verification_results

# Colors for pretty output
YELLOW=\033[1;33m
GREEN=\033[1;32m
NC=\033[0m

.PHONY: help
help: ## 🎯 Display help menu
	@echo -e "${YELLOW}Usage:${NC}"
	@echo "  make [target]"
	@echo ""
	@echo -e "${YELLOW}Targets:${NC}"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  ${GREEN}%-20s${NC} %s\n", $$1, $$2}'

.PHONY: deploy
deploy: package-lambda ## 🚀 Deploy infrastructure and update Lambda function
	@echo -e "${YELLOW}Deploying AWS Infrastructure...${NC}"
	terraform init && terraform apply -auto-approve
	aws lambda update-function-code --function-name $(LAMBDA_FUNCTION_NAME) --zip-file fileb://lambda_function.zip
	@echo -e "${GREEN}Deployment complete!${NC}"

.PHONY: destroy
destroy: ## 💥 Destroy AWS infrastructure
	@echo -e "${YELLOW}Destroying AWS Infrastructure...${NC}"
	terraform destroy -auto-approve
	@echo -e "${GREEN}Infrastructure destroyed!${NC}"

.PHONY: logs
logs: ## 📜 Tail Lambda logs in real-time
	@echo -e "${YELLOW}Fetching Lambda logs...${NC}"
	aws logs tail /aws/lambda/$(LAMBDA_FUNCTION_NAME) --follow --format detailed

.PHONY: queue-status
queue-status: ## 📊 Check the number of messages in the SQS queue
	@echo -e "${YELLOW}Checking SQS queue status...${NC}"
	@if [ -z "$(SQS_QUEUE_URL)" ]; then \
		echo -e "${YELLOW}Error: SQS_QUEUE_URL not set or Terraform output not found${NC}"; \
		exit 1; \
	fi
	aws sqs get-queue-attributes --queue-url $(SQS_QUEUE_URL) --attribute-names ApproximateNumberOfMessages

.PHONY: send-test-emails
send-test-emails: ## 📨 Send test emails to the queue using Docker
	@echo -e "${YELLOW}Sending test emails to SQS queue using Docker...${NC}"
	@if [ -z "$(SQS_QUEUE_URL)" ]; then \
		echo -e "${YELLOW}Error: SQS_QUEUE_URL not set or Terraform output not found${NC}"; \
		exit 1; \
	fi
	docker run --rm -v $(PWD)/scripts:/app/scripts \
		-e AWS_ACCESS_KEY_ID=$$(aws configure get aws_access_key_id) \
		-e AWS_SECRET_ACCESS_KEY=$$(aws configure get aws_secret_access_key) \
		-e AWS_DEFAULT_REGION=$$(aws configure get region) \
		lambda-packager python3 /app/scripts/send_test_email.py --queue-url "$(SQS_QUEUE_URL)"
	@echo -e "${GREEN}Test emails added to queue!${NC}"

.PHONY: check-results
check-results: ## 🔍 Check verification results from DynamoDB using Docker
	@echo -e "${YELLOW}Checking email verification results in DynamoDB using Docker...${NC}"
	docker run --rm -v $(PWD)/scripts:/app/scripts \
		-e AWS_ACCESS_KEY_ID=$$(aws configure get aws_access_key_id) \
		-e AWS_SECRET_ACCESS_KEY=$$(aws configure get aws_secret_access_key) \
		-e AWS_DEFAULT_REGION=$$(aws configure get region) \
		lambda-packager python3 /app/scripts/check_results.py --table-name "$(DYNAMODB_TABLE_NAME)"
	@echo -e "${GREEN}Results checked!${NC}"

.PHONY: package-lambda
package-lambda: ## 🛠️ Package the Lambda function with dependencies in Docker
	@echo -e "${YELLOW}Packaging Lambda function in Docker...${NC}"
	rm -f lambda_function.zip
	docker build -t lambda-packager .
	CID=$$(docker create lambda-packager) && \
	docker cp "$$CID:/app/lambda_function.zip" . && \
	docker rm "$$CID"
	@echo -e "${GREEN}Lambda function packaged!${NC}"

.PHONY: update-lambda
update-lambda: package-lambda ## 🔄 Update Lambda function code
	@echo -e "${YELLOW}Updating Lambda function code...${NC}"
	aws lambda update-function-code --function-name $(LAMBDA_FUNCTION_NAME) --zip-file fileb://lambda_function.zip
	@echo -e "${GREEN}Lambda function updated!${NC}"

.PHONY: run-local
run-local: ## 💻 run locally
	@echo -e "${YELLOW}Running Python dependencies...${NC}"
	docker run --rm -v $(PWD):/app \
		-e AWS_ACCESS_KEY_ID=$$(aws configure get aws_access_key_id) \
		-e AWS_SECRET_ACCESS_KEY=$$(aws configure get aws_secret_access_key) \
		-e AWS_DEFAULT_REGION=$$(aws configure get region) \
		-e SQS_URL="$(SQS_QUEUE_URL)" \
		-e DDB_TABLE="$(DYNAMODB_TABLE_NAME)" \
		-e OUTPUT_TARGET=dynamodb \
		lambda-packager python3 /app/main.py
	@echo -e "${GREEN}Dependencies installed!${NC}"

.PHONY: test
test: ## 🧪 Run local tests
	@echo -e "${YELLOW}Running local tests...${NC}"
	python3 -m unittest discover -s tests -p 'test_*.py'
	@echo -e "${GREEN}Tests completed!${NC}"

.PHONY: clean
clean: ## 🧹 Clean up generated files
	@echo -e "${YELLOW}Cleaning up...${NC}"
	rm -f lambda_function.zip
	rm -rf lambda_package __pycache__ *.pyc
	@echo -e "${GREEN}Cleanup complete!${NC}"
