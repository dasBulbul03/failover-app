import { NextRequest, NextResponse } from 'next/server';
import { query } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const revalidate = 0;

const DB_QUERY_TIMEOUT_MS = 3000;

function queryWithTimeout(sql: string, timeoutMs: number): Promise<any> {
  return Promise.race([
    query(sql),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Database health probe timed out')), timeoutMs)
    ),
  ]);
}

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const probeType = searchParams.get('probe') || searchParams.get('type') || 'readiness';
  const startTime = Date.now();

  // Liveness Probe: Verifies the Next.js process is alive and responding
  if (probeType === 'liveness') {
    return NextResponse.json(
      {
        status: 'healthy',
        probe: 'liveness',
        environment: process.env.APP_ENV || 'azure',
        region: process.env.REGION || 'unknown',
        timestamp: new Date().toISOString(),
      },
      { status: 200 }
    );
  }

  // Readiness Probe: Verifies database connectivity and query execution
  let dbStatus = 'ok';
  let dbLatencyMs = 0;
  let isHealthy = true;

  try {
    const dbStart = Date.now();
    await queryWithTimeout('SELECT 1', DB_QUERY_TIMEOUT_MS);
    dbLatencyMs = Date.now() - dbStart;
  } catch (err: any) {
    isHealthy = false;
    dbStatus = 'error';
    // Log detailed error server-side without leaking internals to public clients
    console.error('[HealthCheck] DB check failed:', err?.message || 'Unknown DB error');
  }

  const totalLatencyMs = Date.now() - startTime;

  const responseBody = {
    status: isHealthy ? 'healthy' : 'unhealthy',
    probe: 'readiness',
    environment: process.env.APP_ENV || 'azure',
    region: process.env.REGION || 'unknown',
    dependencies: {
      database: {
        status: dbStatus,
        latency_ms: isHealthy ? dbLatencyMs : undefined,
      },
    },
    latency_ms: totalLatencyMs,
    timestamp: new Date().toISOString(),
  };

  // Return HTTP 503 if critical dependencies are down so DNS and ALBs mark instance unhealthy
  return NextResponse.json(responseBody, {
    status: isHealthy ? 200 : 503,
    headers: {
      'Cache-Control': 'no-cache, no-store, must-revalidate',
    },
  });
}
