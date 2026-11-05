import { NextResponse } from 'next/server';
import { query } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const revalidate = 0;

export async function GET() {
  let dbStatus = 'ok';
  try {
    await query('SELECT 1');
  } catch (err: any) {
    dbStatus = 'error';
    console.error('DB Health Check Error:', err?.message || err);
  }

  return NextResponse.json({
    status: 'ok',
    environment: process.env.APP_ENV || 'azure',
    db: dbStatus,
    timestamp: new Date().toISOString(),
    region: process.env.REGION || 'unknown',
  });
}
