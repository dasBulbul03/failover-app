import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'FailoverApp - Multi-Cloud Demo',
  description: 'A multi-cloud failover demonstration app built with Next.js and PostgreSQL',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="bg-gray-50 min-h-screen antialiased">{children}</body>
    </html>
  );
}
