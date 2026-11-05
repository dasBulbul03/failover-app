'use client';
import { useState, useEffect, useCallback } from 'react';

interface Message {
  id: number;
  content: string;
  author: string;
  created_at: string;
}

interface HealthData {
  status: string;
  environment: string;
  db: string;
  timestamp: string;
  region: string;
}

export default function Home() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [health, setHealth] = useState<HealthData | null>(null);
  const [author, setAuthor] = useState('');
  const [content, setContent] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null);

  const fetchHealth = useCallback(async () => {
    try {
      const res = await fetch('/api/health');
      if (res.ok) {
        const data: HealthData = await res.json();
        setHealth(data);
      }
    } catch {
      // silently ignore health check errors
    }
  }, []);

  const fetchMessages = useCallback(async () => {
    try {
      const res = await fetch('/api/messages');
      if (res.ok) {
        const data: Message[] = await res.json();
        setMessages(data);
        setLastRefresh(new Date());
      }
    } catch {
      // silently ignore fetch errors
    }
  }, []);

  const refreshAll = useCallback(async () => {
    await Promise.all([fetchHealth(), fetchMessages()]);
  }, [fetchHealth, fetchMessages]);

  useEffect(() => {
    refreshAll();
    const interval = setInterval(refreshAll, 10000);
    return () => clearInterval(interval);
  }, [refreshAll]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!content.trim()) {
      setError('Message content is required.');
      return;
    }
    setSubmitting(true);
    setError(null);
    setSuccessMsg(null);
    try {
      const res = await fetch('/api/messages', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: content.trim(), author: author.trim() || 'Anonymous' }),
      });
      if (!res.ok) {
        const data = await res.json();
        setError(data.error || 'Failed to post message.');
      } else {
        setContent('');
        setSuccessMsg('Message posted successfully!');
        await fetchMessages();
        setTimeout(() => setSuccessMsg(null), 3000);
      }
    } catch {
      setError('Network error. Please try again.');
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async (id: number) => {
    try {
      const res = await fetch(`/api/messages/${id}`, { method: 'DELETE' });
      if (res.ok) {
        setMessages((prev) => prev.filter((m) => m.id !== id));
      }
    } catch {
      // silently ignore
    }
  };

  const env = health?.environment?.toLowerCase() ?? '';
  const isAzure = env === 'azure';
  const isAws = env === 'aws';

  const envBadgeClasses = isAzure
    ? 'bg-blue-100 text-blue-800 border border-blue-300'
    : isAws
    ? 'bg-orange-100 text-orange-800 border border-orange-300'
    : 'bg-gray-100 text-gray-700 border border-gray-300';

  const statusLabel = isAzure
    ? '🟢 Primary (Azure)'
    : isAws
    ? '🟠 Secondary (AWS)'
    : health
    ? `⚪ ${health.environment}`
    : '⏳ Detecting...';

  const dbBadge = health?.db === 'ok'
    ? 'bg-green-100 text-green-700 border border-green-300'
    : 'bg-red-100 text-red-700 border border-red-300';

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-50 to-blue-50 flex flex-col">
      {/* Header */}
      <header className="bg-white shadow-sm border-b border-gray-200">
        <div className="max-w-4xl mx-auto px-4 py-4 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-gray-900 tracking-tight">
              ⚡ FailoverApp
            </h1>
            <p className="text-sm text-gray-500 mt-0.5">Multi-Cloud Demo · Next.js + PostgreSQL</p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {/* Environment badge */}
            <span className={`text-sm font-semibold px-3 py-1 rounded-full ${envBadgeClasses}`}>
              {statusLabel}
            </span>
            {/* DB badge */}
            {health && (
              <span className={`text-xs font-medium px-2 py-1 rounded-full ${dbBadge}`}>
                DB: {health.db}
              </span>
            )}
            {/* Region */}
            {health?.region && health.region !== 'unknown' && (
              <span className="text-xs font-medium px-2 py-1 rounded-full bg-gray-100 text-gray-600 border border-gray-200">
                📍 {health.region}
              </span>
            )}
          </div>
        </div>
      </header>

      <main className="flex-1 max-w-4xl mx-auto w-full px-4 py-8 space-y-8">
        {/* Post a Message */}
        <section className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
          <h2 className="text-lg font-semibold text-gray-800 mb-4">📝 Post a Message</h2>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="flex flex-col sm:flex-row gap-3">
              <div className="flex-1">
                <label htmlFor="author" className="block text-xs font-medium text-gray-500 mb-1 uppercase tracking-wide">
                  Author
                </label>
                <input
                  id="author"
                  type="text"
                  placeholder="Your name (optional)"
                  value={author}
                  onChange={(e) => setAuthor(e.target.value)}
                  className="w-full border border-gray-200 rounded-lg px-3 py-2 text-sm text-gray-800 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent transition"
                  maxLength={100}
                />
              </div>
            </div>
            <div>
              <label htmlFor="content" className="block text-xs font-medium text-gray-500 mb-1 uppercase tracking-wide">
                Message <span className="text-red-400">*</span>
              </label>
              <textarea
                id="content"
                placeholder="Write your message here..."
                value={content}
                onChange={(e) => setContent(e.target.value)}
                rows={3}
                className="w-full border border-gray-200 rounded-lg px-3 py-2 text-sm text-gray-800 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent transition resize-none"
                required
              />
            </div>
            {error && (
              <div className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">
                {error}
              </div>
            )}
            {successMsg && (
              <div className="text-sm text-green-700 bg-green-50 border border-green-200 rounded-lg px-3 py-2">
                {successMsg}
              </div>
            )}
            <div className="flex justify-end">
              <button
                type="submit"
                disabled={submitting}
                className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-300 text-white text-sm font-semibold px-5 py-2 rounded-lg transition-colors shadow-sm"
              >
                {submitting ? (
                  <>
                    <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z" />
                    </svg>
                    Posting...
                  </>
                ) : (
                  'Post Message'
                )}
              </button>
            </div>
          </form>
        </section>

        {/* Messages List */}
        <section className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
          <div className="flex items-center justify-between mb-5">
            <h2 className="text-lg font-semibold text-gray-800">
              💬 Messages{' '}
              <span className="ml-1 text-sm font-normal text-gray-400">({messages.length})</span>
            </h2>
            <div className="flex items-center gap-3">
              {lastRefresh && (
                <span className="text-xs text-gray-400">
                  Last updated {lastRefresh.toLocaleTimeString()}
                </span>
              )}
              <button
                onClick={refreshAll}
                className="text-xs text-blue-600 hover:text-blue-800 font-medium underline"
              >
                Refresh
              </button>
            </div>
          </div>

          {messages.length === 0 ? (
            <div className="text-center py-12 text-gray-400">
              <div className="text-4xl mb-3">📭</div>
              <p className="text-sm">No messages yet. Be the first to post!</p>
            </div>
          ) : (
            <ul className="space-y-3">
              {messages.map((msg) => (
                <li
                  key={msg.id}
                  className="flex items-start gap-3 bg-gray-50 rounded-xl px-4 py-3 border border-gray-100 group"
                >
                  <div className="flex-shrink-0 w-9 h-9 rounded-full bg-blue-100 text-blue-700 flex items-center justify-center text-sm font-bold uppercase">
                    {msg.author.charAt(0)}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-0.5">
                      <span className="text-sm font-semibold text-gray-800">{msg.author}</span>
                      <span className="text-xs text-gray-400">
                        {new Date(msg.created_at).toLocaleString()}
                      </span>
                    </div>
                    <p className="text-sm text-gray-700 leading-relaxed break-words">{msg.content}</p>
                  </div>
                  <button
                    onClick={() => handleDelete(msg.id)}
                    className="flex-shrink-0 opacity-0 group-hover:opacity-100 transition-opacity text-gray-300 hover:text-red-500 text-lg leading-none mt-0.5"
                    title="Delete message"
                    aria-label="Delete message"
                  >
                    ✕
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>

        {/* Health / System Info */}
        {health && (
          <section className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <h2 className="text-lg font-semibold text-gray-800 mb-4">🔍 System Health</h2>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
              {[
                { label: 'Status', value: health.status },
                { label: 'Environment', value: health.environment },
                { label: 'Database', value: health.db },
                { label: 'Region', value: health.region },
              ].map(({ label, value }) => (
                <div key={label} className="bg-gray-50 rounded-xl p-3 border border-gray-100 text-center">
                  <div className="text-xs text-gray-500 uppercase tracking-wide mb-1">{label}</div>
                  <div className="text-sm font-semibold text-gray-800 capitalize">{value}</div>
                </div>
              ))}
            </div>
            <p className="text-xs text-gray-400 mt-3 text-right">
              Auto-refreshes every 10 seconds
            </p>
          </section>
        )}
      </main>

      {/* Footer */}
      <footer className="bg-white border-t border-gray-200 py-4 text-center text-xs text-gray-400">
        Multi-cloud failover demo | Built with Next.js + PostgreSQL
      </footer>
    </div>
  );
}
