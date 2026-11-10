# Terraform S3 State Bootstrap Module

Safe remote state for Terraform on AWS, created once per account.

Terraform state is the single most important file in an infrastructure project. Lose it, corrupt it or let two people write to it at the same time, and Terraform no longer knows what it manages. This module creates storage for state that is hard to lose, hard to break and easy to restore.

## What it creates

| Resource | Why |
|---|---|
| S3 bucket for state, with **versioning** | Every change to the state is kept, so any earlier version can be restored. |
| **KMS encryption** with a customer-managed key (rotation on) | State files often contain passwords and keys. |
| **Public access fully blocked**, bucket owner enforced | State must never be public. |
| A **copy in a second region** (S3 replication, its own KMS key) | A regional problem or an accidental change in one bucket does not lose your state. |
| **HTTPS-only** bucket policy | Requests without TLS are refused. |
| **Delete guard** bucket policy | Nobody, administrators included, can delete the buckets, delete old state versions or switch versioning off while it is on. |
| Lifecycle rule | Old state versions expire after 365 days (configurable); incomplete uploads are cleaned up after 7 days. |

Locking uses Terraform's built-in S3 lock file (`use_lockfile = true`), so **no DynamoDB table** is needed.

## Requirements

- Terraform **1.11 or later**
- AWS provider **6.x**
- Permission to create S3 buckets, KMS keys and an IAM role in the account

## Usage

The module needs two AWS providers: one for the region that holds the state, and one (`aws.replica`) for the second region.

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

module "state" {
  source      = "git::https://github.com/rcheeez/terraform-bootstrap-module.git?ref=v1.0.0"
  bucket_name = "tfstate-123456789012" # must be globally unique

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }
}

output "backend_config" {
  value = module.state.backend_config
}
```

A complete example is in `examples/basic`.

```bash
cd examples/basic
terraform init
terraform plan  -var="bucket_name=tfstate-123456789012"
terraform apply -var="bucket_name=tfstate-123456789012"
```

## Inputs

| Name | Default | Description |
|---|---|---|
| `bucket_name` | (required) | Name of the state bucket. Include something unique, such as your account ID. |
| `replica_bucket_name` | `<bucket_name>-replica` | Name of the copy in the second region. |
| `protect` | `true` | Turns the delete guard on or off. |
| `noncurrent_version_days` | `365` | How long old state versions are kept (minimum 30). |
| `tags` | `{}` | Tags added to every resource. |

## Outputs

| Name | Description |
|---|---|
| `bucket_name`, `bucket_arn` | The state bucket. |
| `replica_bucket_name` | The copy in the second region. |
| `kms_key_arn` | The key that encrypts the state bucket. |
| `backend_config` | A ready-to-paste `backend "s3"` block. |

## Use the bucket from your projects

Paste the `backend_config` output into each project's `terraform` block and give every project its own `key`:

```hcl
terraform {
  backend "s3" {
    bucket       = "tfstate-123456789012"
    key          = "shop-api/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:us-east-1:123456789012:key/..."
    use_lockfile = true
  }
}
```

Then run `terraform init` in that project. If it already has local state, Terraform offers to copy it into the bucket.

## Move this stack's own state into the bucket

The bucket cannot store its own state before it exists, so the first apply keeps state on your machine. Afterwards:

1. Add a `backend "s3"` block to `examples/basic` (or your copy of it) using the `backend_config` output, with a key such as `bootstrap/terraform.tfstate`.
2. Run `terraform init -migrate-state` and answer `yes`.
3. Delete the local `terraform.tfstate` and `terraform.tfstate.backup` files once the state is in the bucket.

## Restore an earlier version of a state file

If a state file is damaged or a bad apply needs undoing at the state level:

```bash
# 1. List the versions of the state file
aws s3api list-object-versions --bucket tfstate-123456789012 \
  --prefix shop-api/prod/terraform.tfstate \
  --query 'Versions[].[VersionId,LastModified,IsLatest]' --output table

# 2. Download the version you want
aws s3api get-object --bucket tfstate-123456789012 \
  --key shop-api/prod/terraform.tfstate --version-id <VERSION_ID> restored.tfstate

# 3. Check it, then make it the current version again
terraform state pull > current.tfstate   # keep a copy of what is there now
aws s3 cp restored.tfstate s3://tfstate-123456789012/shop-api/prod/terraform.tfstate
```

Run `terraform plan` afterwards and read it carefully before applying anything.

## Removing the state storage

This is deliberately hard. Both buckets have `prevent_destroy = true`, and the bucket policy denies deletion while `protect = true`.

1. Make sure no project still uses the bucket.
2. Set `protect = false` and apply. This removes the delete guard from both bucket policies.
3. Change `prevent_destroy` to `false` on both buckets in `main.tf` (Terraform does not allow this to be a variable).
4. Empty both buckets (all versions), then run `terraform destroy`.

KMS keys are scheduled for deletion with a 30-day waiting period, which is the safest setting AWS offers.

## Cost

The running cost is low: two KMS keys (each has a small monthly charge), S3 storage for small state files, and replication of each change to the second region. Check the current AWS pricing for your regions.

---

## Learn more

- **Free chapter:** the reasoning behind every setting in this module, plus how to restore a lost state file: [Terraform State, Done Right](https://archiesgurav.in/products/terraform-state-free-chapter/?utm_source=github&utm_medium=readme&utm_campaign=bootstrap-module)
- **The full book:** 13 chapters taking an empty AWS account to production with Terraform, from state and VPCs to WAF, Auto Scaling, RDS, CI/CD and Multi-AZ: [Production AWS with Terraform](https://archiesgurav.in/products/production-aws-with-terraform/?utm_source=github&utm_medium=readme&utm_campaign=bootstrap-module)

## License

MIT. See [LICENSE](LICENSE).

---

Made by [Archies Gurav](https://archiesgurav.in/?utm_source=github&utm_medium=readme&utm_campaign=bootstrap-module), Cloud & DevOps Engineer.
