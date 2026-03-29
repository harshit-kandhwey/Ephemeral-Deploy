import boto3
from botocore.exceptions import ClientError
from flask import current_app
import uuid
import os


class S3Service:
    def __init__(self):
        self.s3_client = boto3.client(
            "s3", region_name=current_app.config["AWS_REGION"]
        )
        self.bucket = current_app.config["S3_BUCKET"]

    def upload_file(self, file, folder="attachments"):
        """
        Upload file to S3
        Returns: (success, s3_key or error_message)
        """
        try:
            # Generate unique filename
            file_extension = os.path.splitext(file.filename)[1]
            s3_key = f"{folder}/{uuid.uuid4()}{file_extension}"

            # Upload
            self.s3_client.upload_fileobj(
                file,
                self.bucket,
                s3_key,
                ExtraArgs={"ContentType": file.content_type, "ACL": "private"},
            )

            return True, s3_key

        except ClientError as e:
            current_app.logger.error(f"S3 upload error: {e}")
            return False, str(e)

    def get_presigned_url(self, s3_key, expiration=3600):
        """Generate presigned URL for downloading"""
        try:
            url = self.s3_client.generate_presigned_url(
                "get_object",
                Params={"Bucket": self.bucket, "Key": s3_key},
                ExpiresIn=expiration,
            )
            return url
        except ClientError as e:
            current_app.logger.error(f"Presigned URL error: {e}")
            return None

    def delete_file(self, s3_key):
        """Delete file from S3"""
        try:
            self.s3_client.delete_object(Bucket=self.bucket, Key=s3_key)
            return True
        except ClientError as e:
            current_app.logger.error(f"S3 delete error: {e}")
            return False
