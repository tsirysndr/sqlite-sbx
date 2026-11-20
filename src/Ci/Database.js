import { async } from '../Bsdkrun.Internal/foreign.js';

export const queryImpl = spec => async(signal => new Promise((resolve, reject) => {
  let close = () => {};
  const cancel = () => { close(); reject(Error('Database query interrupted')); };
  const timer = setTimeout(() => { close(); reject(Error('Database query timed out')); }, 45000);
  signal.addEventListener('abort', cancel, { once: true });
  (async () => {
    const { createClient } = await import('@libsql/client');
    const client = createClient({ url: spec.url });
    close = () => client.close();
    try { const result = await client.execute(spec.sql); return result.rows.map(row => Array.from(row, String)); }
    finally { client.close(); }
  })().then(resolve, reject).finally(() => { clearTimeout(timer); signal.removeEventListener('abort', cancel); });
}));
