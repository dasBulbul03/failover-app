import { Pool, PoolConfig } from 'pg';

let dbUrl = process.env.DATABASE_URL || '';
const requiresSsl = dbUrl.includes('sslmode=require') || 
  (process.env.NODE_ENV === 'production' && !dbUrl.includes('localhost') && !dbUrl.includes('@db:'));

// Strip query parameters from connection string to avoid driver conflicts
if (dbUrl.includes('?')) {
  dbUrl = dbUrl.split('?')[0];
}

const poolConfig: PoolConfig = {
  connectionString: dbUrl,
  ...(requiresSsl ? { ssl: { rejectUnauthorized: false } } : {}),
};

const pool = new Pool(poolConfig);

export async function query(text: string, params?: any[]) {
  const client = await pool.connect();
  try {
    const result = await client.query(text, params);
    return result;
  } finally {
    client.release();
  }
}

let initPromise: Promise<void> | null = null;

export async function initDb(): Promise<void> {
  if (!initPromise) {
    initPromise = query(`
      CREATE TABLE IF NOT EXISTS messages (
        id SERIAL PRIMARY KEY,
        content TEXT NOT NULL,
        author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    `).then(() => {}).catch(err => {
      initPromise = null;
      throw err;
    });
  }
  return initPromise;
}
