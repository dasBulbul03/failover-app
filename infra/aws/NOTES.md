# AWS Infrastructure State & Import Guide
## FailoverApp — Multi-Cloud Disaster Recovery Platform

### 1. Architecture Overview & Current State Status

- **Primary Cloud**: Amazon Web Services (AWS)
- **Selected Region**: `ap-southeast-2` (Sydney)
- **Live Running Stack**:
  - **Ingress**: AWS Application Load Balancer (`failover-alb-97690356.ap-southeast-2.elb.amazonaws.com`)
  - **Compute**: Amazon ECS Fargate Cluster (`failover-cluster`) & Service (`failover-service`)
  - **Database**: Amazon RDS PostgreSQL 16 (`failoverdb`)
  - **Registry**: Amazon ECR Repository (`failover-app`)

> [!IMPORTANT]
> **State Isolation Notice**:
> The live AWS infrastructure was provisioned and validated directly in the project region. To prevent accidental resource recreation or disruption to live traffic, the local Terraform configuration in `infra/aws` starts with clean state. Follow the import procedures below to bind live resources to your Terraform state.

---

### 2. S3 Remote Backend Setup (Recommended for Team & CI/CD)

Before running `terraform import`, configure remote state storage in an S3 bucket with DynamoDB state locking:

```bash
# 1. Create S3 Bucket in ap-southeast-2
aws s3api create-bucket \
  --bucket "failover-app-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  --region ap-southeast-2 \
  --create-bucket-configuration LocationConstraint=ap-southeast-2

# 2. Enable S3 Bucket Versioning & Encryption
aws s3api put-bucket-versioning \
  --bucket "failover-app-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "failover-app-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 3. Create DynamoDB State Lock Table
aws dynamodb create-table \
  --table-name "failover-app-tflocks" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-2
```

Copy `infra/aws/backend.tf.example` to `infra/aws/backend.tf` and fill in your bucket name:

```hcl
terraform {
  backend "s3" {
    bucket         = "failover-app-tfstate-<YOUR-ACCOUNT-ID>"
    key            = "primary-aws/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "failover-app-tflocks"
    encrypt        = true
  }
}
```

Then initialize:
```bash
cd infra/aws
terraform init
```

---

### 3. Step-by-Step `terraform import` Commands

To import live AWS resources into Terraform state without destroying or recreating them, run these commands:

#### A. Import ECR Repository
```bash
terraform import module.ecr.aws_ecr_repository.app failover-app
```

#### B. Import Networking Layer (VPC, Subnets, Gateways)
```bash
# Obtain VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=failover-app" --query "Vpcs[0].VpcId" --output text)

terraform import module.networking.aws_vpc.main "$VPC_ID"
```

#### C. Import IAM Roles
```bash
terraform import module.iam.aws_iam_role.ecs_execution failover-app-dev-execution-role
terraform import module.iam.aws_iam_role.ecs_task failover-app-dev-task-role
```

#### D. Import Application Load Balancer & Target Group
```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names failover-app-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names failover-app-tg --query "TargetGroups[0].TargetGroupArn" --output text)

terraform import module.alb.aws_lb.main "$ALB_ARN"
terraform import module.alb.aws_lb_target_group.app "$TG_ARN"
```

#### E. Import Amazon RDS PostgreSQL Instance
```bash
terraform import module.rds.aws_db_instance.postgres failover-app-dev-pg
```

#### F. Import ECS Fargate Cluster & Service
```bash
terraform import module.ecs.aws_ecs_cluster.main failover-cluster
terraform import module.ecs.aws_ecs_service.main "failover-cluster/failover-service"
```

#### G. Verify Drift After Import
```bash
terraform plan -var-file="environments/dev/terraform.tfvars"
```

---

### 4. FinOps & Cost Engineering Considerations

| Component | Dev Tier Strategy | Prod Tier Strategy | Monthly Impact (Dev) |
|---|---|---|---|
| **NAT Gateway** | Disabled (`enable_nat_gateway = false`). ECS tasks use public subnets with public IP for ECR image pulls. | 2x Multi-AZ NAT Gateways with Private Subnets. | **$0.00** (Saves ~$65/mo vs 2x NAT GW) |
| **ECS Fargate Compute** | 1x 0.25 vCPU, 0.5 GB RAM task (`desired_count = 1`). | 2-10 tasks with Target Tracking Autoscaling. | **~$2.40/week** (~$10/mo) |
| **Amazon RDS** | `db.t4g.micro` Single-AZ (eligible for AWS 12-month Free Tier: 750 hrs/mo). | Multi-AZ with Read Replica. | **$0.00** (Free Tier) |
| **Application Load Balancer** | 1x ALB (eligible for Free Tier: 750 hrs/mo + 15 LCU). | Multi-AZ ALB with WAF and ACM SSL cert. | **$0.00** (Free Tier) |
| **CloudWatch Logs** | 7-day retention (`log_retention_days = 7`). | 30-day retention with S3 archival. | **<$0.50/mo** |
| **Total Estimated Spend** | **Pilot-Light Dev Profile** | **High-Availability Production** | **~$10 - $12 / month** |
