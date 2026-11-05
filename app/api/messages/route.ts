import { NextRequest, NextResponse } from 'next/server';
import { query, initDb } from '@/lib/db';

export async function GET() {
  try {
    await initDb();
    const result = await query('SELECT * FROM messages ORDER BY created_at DESC LIMIT 50');
    return NextResponse.json(result.rows);
  } catch (error) {
    console.error('GET /api/messages error:', error);
    return NextResponse.json({ error: 'Database error' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    await initDb();
    const { content, author } = await request.json();
    if (!content) return NextResponse.json({ error: 'Content required' }, { status: 400 });
    const result = await query(
      'INSERT INTO messages (content, author) VALUES ($1, $2) RETURNING *',
      [content, author || 'Anonymous']
    );
    return NextResponse.json(result.rows[0], { status: 201 });
  } catch (error) {
    console.error('POST /api/messages error:', error);
    return NextResponse.json({ error: 'Database error' }, { status: 500 });
  }
}
