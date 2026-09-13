from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

from src.services.s3_service import S3Service


def _client_error(code, operation):
    return ClientError({"Error": {"Code": code, "Message": f"{code} on {operation}"}}, operation)


def test_init_reads_region_and_bucket_from_config(app):
    with app.app_context(), patch("src.services.s3_service.boto3.client") as mock_client:
        service = S3Service()
    mock_client.assert_called_once_with("s3", region_name=app.config["AWS_REGION"])
    assert service.bucket == app.config["S3_BUCKET"]


def test_upload_file_returns_success_tuple_with_generated_key(app):
    fake_file = MagicMock(filename="report.pdf", content_type="application/pdf")
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        ok, s3_key = service.upload_file(fake_file)

    assert ok is True
    assert s3_key.startswith("attachments/")
    assert s3_key.endswith(".pdf")
    service.s3_client.upload_fileobj.assert_called_once()
    _, args, kwargs = service.s3_client.upload_fileobj.mock_calls[0]
    assert kwargs["ExtraArgs"] == {"ContentType": "application/pdf", "ACL": "private"}


def test_upload_file_respects_custom_folder(app):
    fake_file = MagicMock(filename="avatar.png", content_type="image/png")
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        ok, s3_key = service.upload_file(fake_file, folder="avatars")

    assert ok is True
    assert s3_key.startswith("avatars/")


def test_upload_file_client_error_returns_false_and_message(app):
    fake_file = MagicMock(filename="report.pdf", content_type="application/pdf")
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        service.s3_client.upload_fileobj.side_effect = _client_error("AccessDenied", "PutObject")
        ok, message = service.upload_file(fake_file)

    assert ok is False
    assert "AccessDenied" in message


def test_upload_file_does_not_catch_non_client_errors(app):
    """Contrast with cache_service's blanket except: a regression to
    `except Exception` here should turn this test red."""
    fake_file = MagicMock(filename="report.pdf", content_type="application/pdf")
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        service.s3_client.upload_fileobj.side_effect = ValueError("unexpected")
        try:
            service.upload_file(fake_file)
            raised = False
        except ValueError:
            raised = True
    assert raised is True


def test_get_presigned_url_returns_url(app):
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        service.s3_client.generate_presigned_url.return_value = "https://example.com/signed"
        url = service.get_presigned_url("attachments/x.pdf")

    assert url == "https://example.com/signed"
    service.s3_client.generate_presigned_url.assert_called_once_with(
        "get_object",
        Params={"Bucket": service.bucket, "Key": "attachments/x.pdf"},
        ExpiresIn=3600,
    )


def test_get_presigned_url_client_error_returns_none(app):
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        service.s3_client.generate_presigned_url.side_effect = _client_error("NoSuchKey", "GetObject")
        url = service.get_presigned_url("attachments/missing.pdf")

    assert url is None


def test_delete_file_returns_true_on_success(app):
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        ok = service.delete_file("attachments/x.pdf")

    assert ok is True
    service.s3_client.delete_object.assert_called_once_with(Bucket=service.bucket, Key="attachments/x.pdf")


def test_delete_file_client_error_returns_false(app):
    with app.app_context(), patch("src.services.s3_service.boto3.client"):
        service = S3Service()
        service.s3_client.delete_object.side_effect = _client_error("AccessDenied", "DeleteObject")
        ok = service.delete_file("attachments/x.pdf")

    assert ok is False
