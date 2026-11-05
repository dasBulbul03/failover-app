import { Pool } from 'pg';

let dbUrl = process.env.DATABASE_URL || '';
// Strip sslmode from connection string if present to avoid driver conflicts
if (dbUrl.includes('?sslmode=')) {
  dbUrl = dbUrl.split('?sslmode=')[0];
}

const pool = new Pool({
  connectionString: dbUrl,
  ssl: {
    rejectUnauthorized: false,
  },
});

export async function query(text: string, params?: any[]) {
  const client = await pool.connect();
  try {
    const result = await client.query(text, params);
    return result;
  } finally {
    client.release();
  }
}

export async function initDb() {
  await query(`
    CREATE TABLE IF NOT EXISTS messages (
      id SERIAL PRIMARY KEY,
      content TEXT NOT NULL,
      author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
      created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    )
  `);
}
