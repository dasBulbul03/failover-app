# FailoverApp — Multi-Cloud Active-Passive Failover System

A resilient, production-ready full-stack application built with **Next.js 14 (App Router)** and **PostgreSQL**, engineered to demonstrate automated and manual multi-cloud disaster recovery and failover between **Microsoft Azure (Primary)** and **Amazon Web Services (Secondary)**.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
   - [System Context & Traffic Flow](#system-context--traffic-flow)
   - [Cloud Workload Topology](#cloud-workload-topology)
   - [Database & Data Persistence](#database--data-persistence)
2. [Software Architecture & Tech Stack](#2-software-architecture--tech-stack)
   - [Application Layer](#application-layer)
   - [Containerization](#containerization)
3. [API Reference & Health Probing](#3-api-reference--health-probing)
   - [Health Check (`/api/health`)](#health-check-apihealth)
   - [Messages API (`/api/messages`)](#messages-api-apimessages)
4. [Infrastructure as Code (IaC)](#4-infrastructure-as-code-iac)
   - [AWS Infrastructure (ECS Fargate + RDS + ALB)](#aws-infrastructure-ecs-fargate--rds--alb)
   - [Azure Infrastructure (App Service + PostgreSQL Flexible)](#azure-infrastructure-app-service--postgresql-flexible)
5. [CI/CD Pipelines](#5-cicd-pipelines)
   - [Workflow Catalog](#workflow-catalog)
   - [Required Repository Secrets](#required-repository-secrets)
6. [Multi-Cloud Failover Playbook](#6-multi-cloud-failover-playbook)
   - [Automated DNS Failover](#automated-dns-failover)
   - [Manual Failover via GitHub Actions](#manual-failover-via-github-actions)
7. [Local Development & Testing](#7-local-development--testing)
   - [Quickstart with Docker Compose](#quickstart-with-docker-compose)
   - [Manual Setup](#manual-setup)
   - [Linting and Type Checking](#linting-and-type-checking)
8. [Current Deployment Status](#8-current-deployment-status)

---

## 1. Architecture Overview

### System Context & Traffic Flow

The system employs an **Active-Passive Multi-Cloud Topology**. Normal user traffic is routed to Azure (Primary). Global DNS health checks continuously probe the `/api/health` endpoint. In the event of an Azure region degradation or outage, traffic automatically or manually diverts to AWS (Secondary).

```mermaid
flowchart TD
    User([Internet Users / Clients]) --> DNS[DNS Routing Layer: Azure Traffic Manager / Route 53]

    subgraph Primary ["🟢 Azure Cloud (Primary Region - East US)"]
        TM_Azure[Priority 1 Endpoint]
        AppService[Azure App Service: Linux Web App]
        AzureDB[(Azure Database for PostgreSQL)]
        AppService --> AzureDB
    end

    subgraph Secondary ["🟠 AWS Cloud (Secondary Region - Sydney ap-southeast-2)"]
        TM_AWS[Priority 2 Endpoint]
        ALB[Application Load Balancer]
        ECS[ECS Fargate Tasks: failover-service]
        RDS[(Amazon RDS: PostgreSQL 16)]
        ALB --> ECS
        ECS --> RDS
    end

    DNS -- "Normal Traffic (Priority 1)" --> TM_Azure --> AppService
    DNS -. "Failover Traffic (On Failure / Drill)" .-> TM_AWS --> ALB
```

### Cloud Workload Topology

| Layer | Microsoft Azure (Primary) | Amazon Web Services (Secondary) |
| :--- | :--- | :--- |
| **Compute Form Factor** | Azure App Service (Linux Web App, Node 20 LTS) | AWS ECS Fargate (Serverless Containers, 0.25 vCPU / 512 MB) |
| **Ingress / Load Balancer** | Azure App Service Default Ingress (`azurewebsites.net`) | AWS Application Load Balancer (`aws_lb`) with HTTP/80 Listener |
| **Container Registry** | Azure Container Registry (ACR) | Amazon Elastic Container Registry (ECR) |
| **Database** | Azure Database for PostgreSQL Flexible Server | Amazon RDS for PostgreSQL 16 (Private subnet, db.t4g.micro) |
| **Logging & Monitoring** | Azure Log Analytics & App Service Diagnostics | Amazon CloudWatch Log Group (`/ecs/failover-app`, 7-day retention) |
| **Region** | `eastus` | `ap-southeast-2` (Sydney) |

### Database & Data Persistence

- **Schema Definition**: The database holds a `messages` table storing board submissions:
  ```sql
  CREATE TABLE IF NOT EXISTS messages (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
  );
  ```
- **Connection Management ([lib/db.ts](lib/db.ts))**:
  - Connection pooling via `pg.Pool`.
  - Conditional SSL negotiation: enforces SSL for production clouds (RDS/Azure) while keeping local Docker connections unencrypted.
  - Runtime memoization: table initialization runs once per container lifecycle, preventing database catalog contention.

---

## 2. Software Architecture & Tech Stack

### Application Layer
- **Framework**: Next.js 14 with App Router (`app/` directory).
- **Language**: TypeScript 5 (`strict: true`).
- **Styling**: Tailwind CSS with auto-refresh UI (polls every 10 seconds).
- **Environment Detection**: The client UI displays an interactive badge indicating active cloud provider (`azure` vs `aws`) and datacenter region from runtime environment variables (`APP_ENV`, `REGION`).

### Containerization
- **Dockerfile ([Dockerfile](Dockerfile))**:
  - **Stage 1 (deps)**: Installs production dependencies using `npm ci` on `node:20-alpine`.
  - **Stage 2 (builder)**: Compiles the Next.js application into a standalone bundle (`output: 'standalone'`).
  - **Stage 3 (runner)**: Minimal runtime container using a locked non-root user (`nextjs:nodejs`, UID 1001). Exposes port `3000`.

---

## 3. API Reference & Health Probing

### Health Check (`/api/health`)

Used by DNS failover controllers (Azure Traffic Manager, AWS Route 53, Cloudflare Health Checks) to verify compute and database health.

- **Method**: `GET`
- **Response Headers**: `Cache-Control: no-cache, no-store`
- **Success Response (`200 OK`)**:
  ```json
  {
    "status": "ok",
    "environment": "aws",
    "db": "ok",
    "timestamp": "2026-11-20T16:19:49.240Z",
    "region": "ap-southeast-2"
  }
  ```
- **Failure Behavior**: If PostgreSQL is unreachable, `db` returns `"error"`.

### Messages API (`/api/messages`)

- `GET /api/messages`: Returns the 50 most recent messages.
- `POST /api/messages`: Creates a message. Body: `{"content": "string", "author": "string"}`.
- `DELETE /api/messages/:id`: Deletes a specific message by its integer ID.

---

## 4. Infrastructure as Code (IaC)

### AWS Infrastructure (ECS Fargate + RDS + ALB)
Located in [`infra/aws/`](infra/aws/).

* **[main.tf](infra/aws/main.tf)**:
  - Discovers default VPC and subnets dynamically.
  - Provisions ALB with target group routing `/api/health` checks to port 3000.
  - Creates least-privilege security groups:
    - `alb-sg`: Inbound HTTP 80 from `0.0.0.0/0`.
    - `ecs-tasks-sg`: Inbound TCP 3000 from `alb-sg` only.
    - `rds-sg`: Inbound TCP 5432 from `ecs-tasks-sg` only.
  - Provisions private RDS PostgreSQL 16 instance.
  - Deploys ECS Fargate Task Definition and Service (`failover-service`).
* **[variables.tf](infra/aws/variables.tf)**: Region (`ap-southeast-2`), application name, and database credentials.
* **[outputs.tf](infra/aws/outputs.tf)**: Exports live ALB DNS name, health check URL, and ECR repository URL.
* **[deploy.sh](infra/aws/deploy.sh)**: Automates multi-arch Docker builds (`linux/amd64`), ECR push, and ECS rolling deployments.

### Azure Infrastructure (App Service + PostgreSQL Flexible)
Located in [`infra/azure/`](infra/azure/).

* **[main.tf](infra/azure/main.tf)**: Defines Resource Group, Linux App Service Plan (B1), PostgreSQL Flexible Server (Burstable B1ms), and Web App.
* **[main.bicep](infra/azure/main.bicep)**: Azure-native Bicep template alternative for automated CLI deployments.
* **[deploy.sh](infra/azure/deploy.sh)**: One-click script to deploy the Bicep template via `az deployment group create`.

---

## 5. CI/CD Pipelines

GitHub Actions workflows are located in [`.github/workflows/`](.github/workflows/):

### Workflow Catalog

```
.github/workflows/
├── aws-deploy.yml              # Triggered on push to main (or manual dispatch) -> Deploys to AWS ECS
├── azure-deploy.yml            # Manual trigger (or promote) -> Deploys to Azure Web App
├── multi-cloud-release.yml     # Orchestrates parallel/selective release to both clouds
└── failover-trigger.yml        # On-demand manual drill: toggles Traffic Manager endpoints
```

1. **[aws-deploy.yml](.github/workflows/aws-deploy.yml)**:
   - Steps: Checkout → Node 20 Setup → `npm ci` → `npm test` (ESLint + TypeScript type check) → AWS OIDC/Key Authentication → Docker Buildx (`linux/amd64`) → Push ECR → `aws ecs update-service --force-new-deployment` → Automated HTTP 200 verification on live ALB.
2. **[azure-deploy.yml](.github/workflows/azure-deploy.yml)**:
   - Steps: Quality Gates → Azure Docker Login → ACR Build & Push → Deploy Web App Container → Probe live Azure health check.
3. **[multi-cloud-release.yml](.github/workflows/multi-cloud-release.yml)**:
   - Allows selecting deployment targets (`both`, `azure-only`, or `aws-only`).
   - Runs test suites once, pushes images to both cloud registries, and reports a side-by-side release status matrix in the GitHub Step Summary.
4. **[failover-trigger.yml](.github/workflows/failover-trigger.yml)**:
   - Takes input action `failover-to-aws` or `failback-to-azure`.
   - Modifies Azure Traffic Manager endpoint status using the Azure CLI and verifies secondary endpoint health.

### Required Repository Secrets

Configure the following secrets in **GitHub Repository Settings > Secrets and variables > Actions**:

| Secret Name | Cloud | Purpose |
| :--- | :---: | :--- |
| `AWS_ACCESS_KEY_ID` | AWS | IAM user access key for CI deployments |
| `AWS_SECRET_ACCESS_KEY` | AWS | IAM user secret access key |
| `AWS_ALB_DNS` | AWS | *(Optional)* Override ALB DNS name for health verification |
| `AZURE_CREDENTIALS` | Azure | Service principal JSON credentials (`az ad sp create-for-rbac`) |
| `AZURE_WEBAPP_NAME` | Azure | Azure Linux Web App resource name |
| `ACR_LOGIN_SERVER` | Azure | Azure Container Registry login domain (e.g. `myregistry.azurecr.io`) |
| `ACR_USERNAME` | Azure | ACR admin or service principal username |
| `ACR_PASSWORD` | Azure | ACR access password |
| `AZURE_RESOURCE_GROUP` | Azure | Resource group containing Traffic Manager profile |
| `TM_PROFILE_NAME` | Azure | Azure Traffic Manager profile name |

---

## 6. Multi-Cloud Failover Playbook

### Automated DNS Failover

Configured using **Azure Traffic Manager** or **AWS Route 53**:
1. Create a Traffic Manager profile with **Priority Routing** (TTL: 60 seconds).
2. Set **Endpoint 1 (Primary)** to Azure App Service (`azurewebsites.net`), Priority `1`.
3. Set **Endpoint 2 (Secondary)** to AWS ALB DNS name, Priority `2`.
4. Monitor probe: Protocol `HTTP`/`HTTPS`, Port `80`/`443`, Path `/api/health`.

### Manual Failover via GitHub Actions

To simulate a disaster recovery scenario or perform zero-downtime maintenance:
1. Navigate to **Actions** in GitHub.
2. Select **Manual Failover Trigger** and click **Run workflow**.
3. Choose:
   - `failover-to-aws`: Disables the primary Azure endpoint, forcing 100% of incoming DNS traffic to AWS.
   - `failback-to-azure`: Re-enables the primary endpoint once Azure service is restored.

---

## 7. Local Development & Testing

### Quickstart with Docker Compose

Spin up a local PostgreSQL 16 database and the Next.js app in one command:

```bash
docker compose up --build
```
- Web Application: [http://localhost:3000](http://localhost:3000)
- PostgreSQL Database: `localhost:5432` (`user: postgres`, `password: postgres`, `db: failoverdb`)

### Manual Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/dasBulbul03/failover-app.git
   cd failover-app
   ```
2. **Configure environment variables**:
   ```bash
   cp .env.local.example .env.local
   ```
   Edit `.env.local`:
   ```env
   DATABASE_URL=postgresql://postgres:postgres@localhost:5432/failoverdb
   APP_ENV=local
   REGION=local
   ```
3. **Install dependencies**:
   ```bash
   npm install
   ```
4. **Run development server**:
   ```bash
   npm run dev
   ```

### Linting and Type Checking

Run the full CI validation suite locally:

```bash
npm test
```
*Executes `next lint` followed by `tsc --noEmit`.*

---

## 8. Current Deployment Status

- **AWS Secondary Deployment**: **LIVE & HEALTHY** 🟢
  - **Load Balancer Endpoint**: `http://failover-alb-97690356.ap-southeast-2.elb.amazonaws.com`
  - **Health Check Probe**: `http://failover-alb-97690356.ap-southeast-2.elb.amazonaws.com/api/health`
  - **Region**: `ap-southeast-2` (Sydney)
- **Azure Primary Deployment**: Pending credential provisioning in GitHub Secrets.
