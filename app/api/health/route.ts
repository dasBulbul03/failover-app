import { NextResponse } from 'next/server';
import { query } from '@/lib/db';

export async function GET() {
  let dbStatus = 'ok';
  try {
    await query('SELECT 1');
  } catch {
    dbStatus = 'error';
  }

  return NextResponse.json({
    status: 'ok',
    environment: process.env.APP_ENV || 'azure',
    db: dbStatus,
    timestamp: new Date().toISOString(),
    region: process.env.REGION || 'unknown',
  });
}
