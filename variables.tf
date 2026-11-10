variable "bucket_name" {
  description = "Name of the state bucket. S3 bucket names are global, so include something unique such as your account ID."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,53}[a-z0-9]$", var.bucket_name))
    error_message = "Use 3-55 lowercase letters, numbers, dots or hyphens (8 characters are kept free for the \"-replica\" suffix)."
  }
}

variable "replica_bucket_name" {
  description = "Name of the copy in the second region. Defaults to \"<bucket_name>-replica\"."
  type        = string
  default     = null
}

variable "protect" {
  description = "Deny deleting the buckets, deleting old state versions and suspending versioning. Set to false only when you really mean to remove the state storage."
  type        = bool
  default     = true
}

variable "noncurrent_version_days" {
  description = "How long old (non-current) state versions are kept before they expire."
  type        = number
  default     = 365

  validation {
    condition     = var.noncurrent_version_days >= 30
    error_message = "Keep old state versions for at least 30 days."
  }
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
