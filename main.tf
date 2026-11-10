# Safe remote state for Terraform on AWS:
#   - a versioned, KMS-encrypted S3 bucket with all public access blocked
#   - a live copy in a second region (S3 replication)
#   - a delete guard and an HTTPS-only policy on both buckets
# Locking uses Terraform's built-in S3 lock file (use_lockfile = true), so no DynamoDB table is needed.

locals {
  replica_bucket_name = coalesce(var.replica_bucket_name, "${var.bucket_name}-replica")
}

# ── Encryption keys (one per region) ──

resource "aws_kms_key" "state" {
  description             = "Encrypts the Terraform state bucket ${var.bucket_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_kms_key" "replica" {
  provider                = aws.replica
  description             = "Encrypts the Terraform state replica bucket ${local.replica_bucket_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "replica" {
  provider      = aws.replica
  name          = "alias/${local.replica_bucket_name}"
  target_key_id = aws_kms_key.replica.key_id
}

# ── State bucket ──

resource "aws_s3_bucket" "state" {
  bucket = var.bucket_name
  tags   = var.tags

  # A second guard on top of the bucket policy: Terraform refuses to plan the bucket's deletion.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# ── Replica bucket in the second region ──

resource "aws_s3_bucket" "replica" {
  provider = aws.replica
  bucket   = local.replica_bucket_name
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.replica.arn
    }
    bucket_key_enabled = true
  }
}

# ── Replication: every state change is copied to the second region ──

data "aws_iam_policy_document" "replication_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "${var.bucket_name}-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "replication" {
  statement {
    sid       = "ReadSourceConfiguration"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadSourceObjects"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "WriteReplicaObjects"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${aws_s3_bucket.replica.arn}/*"]
  }

  statement {
    sid       = "DecryptWithSourceKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.state.arn]
  }

  statement {
    sid       = "EncryptWithReplicaKey"
    actions   = ["kms:Encrypt"]
    resources = [aws_kms_key.replica.arn]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "replicate-terraform-state"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_s3_bucket_replication_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "copy-state-to-second-region"
    status = "Enabled"
    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"
      encryption_configuration {
        replica_kms_key_id = aws_kms_key.replica.arn
      }
    }
  }

  # Replication needs versioning on both buckets first.
  depends_on = [aws_s3_bucket_versioning.state, aws_s3_bucket_versioning.replica, aws_iam_role_policy.replication]
}

# ── Bucket policies: HTTPS only, plus the delete guard ──

data "aws_iam_policy_document" "guard" {
  for_each = {
    state   = aws_s3_bucket.state.arn
    replica = aws_s3_bucket.replica.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value, "${each.value}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = var.protect ? [1] : []
    content {
      sid       = "DenyDeletingStateHistory"
      effect    = "Deny"
      actions   = ["s3:DeleteBucket", "s3:DeleteObjectVersion", "s3:PutBucketVersioning"]
      resources = [each.value, "${each.value}/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.guard["state"].json

  # Applied last: once the guard is on, versioning can no longer be changed.
  depends_on = [aws_s3_bucket_public_access_block.state, aws_s3_bucket_replication_configuration.state]
}

resource "aws_s3_bucket_policy" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  policy   = data.aws_iam_policy_document.guard["replica"].json

  depends_on = [aws_s3_bucket_public_access_block.replica, aws_s3_bucket_replication_configuration.state]
}
