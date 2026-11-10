output "bucket_name" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "replica_bucket_name" {
  description = "Name of the copy in the second region."
  value       = aws_s3_bucket.replica.id
}

output "kms_key_arn" {
  description = "KMS key that encrypts the state bucket."
  value       = aws_kms_key.state.arn
}

output "backend_config" {
  description = "Paste this into the terraform block of each project that stores its state here (change the key per project)."
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.state.id}"
      key          = "my-project/terraform.tfstate"
      region       = "${aws_s3_bucket.state.region}"
      encrypt      = true
      kms_key_id   = "${aws_kms_key.state.arn}"
      use_lockfile = true
    }
  EOT
}
