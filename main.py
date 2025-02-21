import os
import json
import asyncio
import aiosmtplib
import dns.asyncresolver
import dns.resolver
import re
import socket
import boto3
import logging
import aiofiles

from abc import ABC, abstractmethod
from typing import List, Dict, Optional
from dataclasses import dataclass
from functools import lru_cache
from contextlib import asynccontextmanager
from asyncio import Lock
from time import monotonic

# ─────────────────────────── Configuration & Constants ─────────────────────────── #

logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
logger.handlers = [handler]

@dataclass
class Config:
    """Centralized configuration class using environment variables."""
    sender_email: str = os.getenv("SENDER_EMAIL", "test@example.com")
    smtp_timeout: int = int(os.getenv("SMTP_TIMEOUT", 10))
    socket_timeout: int = int(os.getenv("SOCKET_TIMEOUT", 5))
    batch_size: int = int(os.getenv("BATCH_SIZE", 10))
    input_source: str = os.getenv("INPUT_SOURCE", "sqs")
    output_target: str = os.getenv("OUTPUT_TARGET", "dynamodb")
    input_file: str = os.getenv("LOCAL_INPUT_FILE", "emails.txt")
    output_file: str = os.getenv("LOCAL_OUTPUT_FILE", "results.json")
    smtp_rate_limit: float = float(os.getenv("SMTP_RATE_LIMIT", 10.0))
    smtp_burst_capacity: int = int(os.getenv("SMTP_BURST_CAPACITY", 20))

CONFIG = Config()

DISPOSABLE_EMAIL_DOMAINS = frozenset({
    "mailinator.com", "guerrillamail.com", "tempmail.com", "10minutemail.com"
})

ROLE_BASED_EMAILS = frozenset({"admin", "support", "info", "noreply", "sales", "contact"})

EMAIL_REGEX = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")

# ─────────────────────────── Rate Limiter ─────────────────────────── #

class RateLimiter:
    def __init__(self, rate: float, capacity: int):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
        self.last_refill = monotonic()
        self.lock = Lock()

    async def acquire(self):
        async with self.lock:
            await self._refill()
            while self.tokens < 1:
                wait_time = (1 - self.tokens) / self.rate
                logger.debug(f"Rate limit hit, waiting {wait_time:.2f}s")
                await asyncio.sleep(wait_time)
                await self._refill()
            self.tokens -= 1

    async def _refill(self):
        now = monotonic()
        elapsed = now - self.last_refill
        new_tokens = elapsed * self.rate
        self.tokens = min(self.capacity, self.tokens + new_tokens)
        self.last_refill = now

# ─────────────────────────── Advanced Async Email Verification ─────────────────────────── #

class EmailVerifier:
    def __init__(self):
        self.resolver = dns.asyncresolver.Resolver()
        self.resolver.timeout = CONFIG.socket_timeout
        self.resolver.lifetime = CONFIG.socket_timeout
        self.rate_limiter = RateLimiter(CONFIG.smtp_rate_limit, CONFIG.smtp_burst_capacity)
        self.dynamodb = boto3.resource("dynamodb")
        self.table = self.dynamodb.Table(os.getenv("DDB_TABLE", "email_verification_results"))
        logger.info(f"Initialized DynamoDB table: {self.table.name}")

    @lru_cache(maxsize=1000)
    def validate_syntax(self, email: str) -> bool:
        is_valid = bool(EMAIL_REGEX.match(email))
        logger.info(f"Validating syntax for {email}: {is_valid}")
        return is_valid

    @asynccontextmanager
    async def smtp_client(self, mx_host: str) -> aiosmtplib.SMTP:
        await self.rate_limiter.acquire()
        client = aiosmtplib.SMTP(hostname=mx_host, port=25, timeout=CONFIG.smtp_timeout)
        try:
            await client.connect()
            yield client
        finally:
            try:
                await client.quit()
            except:
                pass

    async def get_mx_records(self, domain: str) -> List[str]:
        try:
            answers = await self.resolver.resolve(domain, "MX")
            mx_records = [str(r.exchange).rstrip('.') for r in sorted(answers, key=lambda x: x.preference)]
            logger.info(f"MX records for {domain}: {mx_records}")
            return mx_records
        except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer) as e:
            logger.info(f"No MX records for {domain}: {e}")
            return []
        except Exception as e:
            logger.error(f"MX lookup failed for {domain}: {e}")
            return []

    async def check_smtp_connection(self, mx_host: str) -> bool:
        try:
            sock = socket.create_connection((mx_host, 25), timeout=CONFIG.socket_timeout)
            sock.close()
            logger.info(f"SMTP connection successful for {mx_host}")
            return True
        except Exception as e:
            logger.info(f"SMTP unreachable for {mx_host}: {e}")
            return False

    async def verify_smtp(self, email: str, mx_records: List[str]) -> Dict[str, str]:
        result = {"email": email, "status": "undeliverable", "reason": ""}
        for mx in mx_records:
            try:
                async with self.smtp_client(mx) as client:
                    await client.ehlo(socket.getfqdn())
                    await client.mail(CONFIG.sender_email)
                    code, message = await client.rcpt(email)
                    logger.info(f"SMTP response for {email} from {mx}: {code} {message}")
                    if code == 250:
                        return {"email": email, "status": "valid", "reason": "Mailbox exists"}
                    elif code in (550, 551, 552, 553):
                        return {"email": email, "status": "invalid", "reason": f"Mailbox rejected: {message}"}
                    elif code in (421, 451, 452):
                        return {"email": email, "status": "retry_later", "reason": f"Temporary failure: {message}"}
                    else:
                        result["reason"] = f"Unexpected SMTP code: {code} {message}"
            except aiosmtplib.SMTPException as e:
                result["reason"] = f"SMTP error with {mx}: {e}"
            except Exception as e:
                result["reason"] = f"Connection error with {mx}: {e}"
        logger.info(f"SMTP verification result for {email}: {result}")
        return result

    async def is_catch_all(self, domain: str, mx_records: List[str]) -> bool:
        test_email = f"fakeuser{os.urandom(4).hex()}@{domain}"
        logger.info(f"Testing catch-all with {test_email}")
        for mx in mx_records:
            try:
                async with self.smtp_client(mx) as client:
                    await client.ehlo(socket.getfqdn())
                    await client.mail(CONFIG.sender_email)
                    code, _ = await client.rcpt(test_email)
                    logger.info(f"Catch-all test response for {test_email} from {mx}: {code}")
                    if code == 250:
                        return True
            except:
                continue
        return False

    async def process_email(self, email: str) -> Dict[str, str]:
        logger.info(f"Processing email: {email}")
        if not self.validate_syntax(email):
            result = {"email": email, "status": "invalid", "reason": "Invalid syntax"}
            logger.info(f"Early return due to invalid syntax: {result}")
            return result

        local_part, domain = email.rsplit("@", 1)
        domain, local_part = domain.lower(), local_part.lower()
        logger.info(f"Extracted domain: {domain}, local_part: {local_part}")

        if domain in DISPOSABLE_EMAIL_DOMAINS:
            result = {"email": email, "status": "invalid", "reason": "Disposable email"}
            logger.info(f"Disposable email detected: {result}")
            return result

        if local_part in ROLE_BASED_EMAILS:
            result = {"email": email, "status": "caution", "reason": "Role-based email"}
            logger.info(f"Role-based email detected: {result}")
            return result

        mx_records = await self.get_mx_records(domain)
        if not mx_records:
            result = {"email": email, "status": "invalid", "reason": "No MX records found"}
            logger.info(f"No MX records: {result}")
        else:
            result = {"email": email, "status": "valid", "reason": "MX records found"}  # Simplified for testing
            logger.info(f"MX records found: {result}")

        # DynamoDB write
        logger.info(f"Attempting DynamoDB operation for {email}")
        try:
            logger.info(f"Checking if {email} exists in DynamoDB")
            existing = await asyncio.to_thread(self.table.get_item, Key={"email": email})
            if "Item" in existing:
                logger.info(f"Existing record found: {existing['Item']}")
                logger.info(f"Updating DynamoDB with: {result}")
                await asyncio.to_thread(
                    self.table.update_item,
                    Key={"email": email},
                    UpdateExpression="SET #s = :status, #r = :reason",
                    ExpressionAttributeNames={"#s": "status", "#r": "reason"},
                    ExpressionAttributeValues={
                        ":status": result["status"],
                        ":reason": result["reason"]
                    }
                )
                logger.info(f"Successfully updated DynamoDB record for {email}")
            else:
                logger.info(f"No existing record, inserting: {result}")
                await asyncio.to_thread(self.table.put_item, Item=result)
                logger.info(f"Successfully inserted DynamoDB record for {email}")
        except Exception as e:
            logger.error(f"DynamoDB operation failed for {email}: {e}", exc_info=True)

        return result

# ─────────────────────────── AWS Lambda Entry Point ─────────────────────────── #

def lambda_handler(event, context):
    """AWS Lambda entry point for SQS trigger with DynamoDB storage."""
    logger.info(f"Received event: {json.dumps(event)}")
    async def process_emails(emails: List[str]) -> List[Dict[str, str]]:
        verifier = EmailVerifier()
        results = []
        logger.info(f"Processing {len(emails)} emails")
        for i in range(0, len(emails), CONFIG.batch_size):
            batch = emails[i:i + CONFIG.batch_size]
            batch_results = await asyncio.gather(*[verifier.process_email(email) for email in batch])
            results.extend(batch_results)
            logger.info(f"Processed batch {i // CONFIG.batch_size + 1}: {len(batch)} emails")
        logger.info(f"All results: {results}")
        return results

    try:
        # Extract emails from SQS event
        sqs_records = event.get("Records", [])
        logger.info(f"Found {len(sqs_records)} SQS records")
        if not sqs_records:
            logger.warning("No SQS records found in event")
            return {"statusCode": 200, "body": json.dumps({"message": "No emails to process"})}

        emails = [record["body"] for record in sqs_records]
        logger.info(f"Extracted emails: {emails}")
        if not emails:
            logger.warning("No valid emails extracted from SQS event")
            return {"statusCode": 200, "body": json.dumps({"message": "No emails to process"})}

        # Process emails and return results
        results = asyncio.run(process_emails(emails))
        logger.info(f"Final results: {results}")
        return {"statusCode": 200, "body": json.dumps({"message": "Processed emails", "results": results})}
    except Exception as e:
        logger.error(f"Lambda execution failed: {e}", exc_info=True)
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}

# ─────────────────────────── CLI Entry Point (for local testing) ─────────────────────────── #

if __name__ == "__main__":
    # Simulate an SQS event for local testing
    sample_event = {
        "Records": [
            {"body": "test@gmail.com"},
            {"body": "invalid@nonexistent.com"}
        ]
    }
    lambda_handler(sample_event, None)
