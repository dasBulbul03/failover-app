import { NextRequest, NextResponse } from 'next/server';
import { query } from '@/lib/db';

export async function DELETE(
  _request: NextRequest,
  { params }: { params: { id: string } }
) {
  try {
    const id = parseInt(params.id, 10);
    if (isNaN(id)) {
      return NextResponse.json({ error: 'Invalid ID' }, { status: 400 });
    }
    const result = await query('DELETE FROM messages WHERE id = $1 RETURNING *', [id]);
    if (result.rowCount === 0) {
      return NextResponse.json({ error: 'Message not found' }, { status: 404 });
    }
    return NextResponse.json({ success: true, deleted: result.rows[0] });
  } catch (error) {
    console.error('DELETE /api/messages/[id] error:', error);
    return NextResponse.json({ error: 'Database error' }, { status: 500 });
  }
}
