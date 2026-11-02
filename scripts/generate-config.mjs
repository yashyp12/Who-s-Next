import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const supabaseUrl = process.env.SUPABASE_URL?.trim();
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY?.trim();

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Netlify build requires SUPABASE_URL and SUPABASE_ANON_KEY environment variables.');
}

const parsedUrl = new URL(supabaseUrl);
if (parsedUrl.protocol !== 'https:' || !parsedUrl.hostname.endsWith('.supabase.co')) {
  throw new Error('SUPABASE_URL must be a valid HTTPS Supabase project URL.');
}

const output = resolve(dirname(fileURLToPath(import.meta.url)), '../site/config.js');
const source = `// Generated during the Netlify build. Contains only browser-safe public configuration.
window.WHOS_NEXT_CONFIG = ${JSON.stringify({ supabaseUrl, supabaseAnonKey }, null, 2)};
`;

await writeFile(output, source, { encoding: 'utf8', mode: 0o644 });
console.log('Generated site/config.js with public Supabase browser configuration.');
