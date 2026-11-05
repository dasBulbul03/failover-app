# FailoverApp — Multi-Cloud Failover Demo

A production-ready Next.js 14 (App Router) application demonstrating multi-cloud failover between Azure and AWS, backed by PostgreSQL.

## Features

- **Messages CRUD Board** – Post, view, and delete messages stored in PostgreSQL
- **Health Check Endpoint** – `/api/health` returns JSON with environment, DB status, region, and timestamp
- **Environment Detection** – UI auto-detects Azure vs AWS via `APP_ENV` env var and shows a coloured status badge
- **Auto-Refresh** – Page data refreshes every 10 seconds
- **Standalone Build** – `output: 'standalone'` for easy containerisation

## Tech Stack

- **Framework**: Next.js 14 (App Router, TypeScript)
- **Database**: PostgreSQL via `pg`
- **Styling**: Tailwind CSS

## Getting Started

### 1. Configure environment

Copy the example env file and fill in your values:

```bash
cp .env.local.example .env.local
```

Edit `.env.local`:

```env
DATABASE_URL=postgresql://user:password@localhost:5432/failoverdb
APP_ENV=azure        # or "aws" for the secondary region
REGION=eastus        # descriptive region label shown in the UI
```

### 2. Install dependencies

```bash
npm install
```

### 3. Run development server

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

### 4. Build for production

```bash
npm run build
npm start
```

## API Routes

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | Health check — returns `{ status, environment, db, timestamp, region }` |
| `GET` | `/api/messages` | List latest 50 messages |
| `POST` | `/api/messages` | Create a message `{ content, author? }` |
| `DELETE` | `/api/messages/[id]` | Delete a message by ID |

## Health Check Response

```json
{
  "status": "ok",
  "environment": "azure",
  "db": "ok",
  "timestamp": "2024-01-01T00:00:00.000Z",
  "region": "eastus"
}
```

The `environment` field is controlled by the `APP_ENV` environment variable (defaults to `"azure"`). Set it to `"aws"` on your secondary deployment.

## Database

The app automatically creates the `messages` table on first request — no manual migration needed.

```sql
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

## Failover Flow

```
         Load Balancer / DNS Failover
                    │
        ┌───────────┴───────────┐
        │                       │
  🟢 Azure (Primary)      🟠 AWS (Secondary)
  APP_ENV=azure           APP_ENV=aws
  REGION=eastus           REGION=us-east-1
        │                       │
        └───────────┬───────────┘
                    │
             PostgreSQL DB
         (replicated or shared)
```

Both deployments point to the same (or replicated) PostgreSQL database. The health check endpoint lets your load balancer or failover controller verify each node is alive and connected to DB.
