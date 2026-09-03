import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const plugin = JSON.parse(await fs.readFile('.codex-plugin/plugin.json', 'utf8'));
const kinds = [['tips', 'tip'], ['announcements', 'announcement'], ['articles', 'article']];
const read = async file => {
  const source = (await fs.readFile(file, 'utf8')).replaceAll('\r\n', '\n');
  const match = source.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) throw new Error(`${file} requires YAML front matter`);
  const meta = Object.fromEntries(match[1].split('\n').filter(Boolean).map(line => {
    const at = line.indexOf(':');
    const key = line.slice(0, at).trim();
    let value = line.slice(at + 1).trim().replace(/^['"]|['"]$/g, '');
    if (value.startsWith('[')) value = value.slice(1, -1).split(',').map(item => item.trim()).filter(Boolean);
    return [key, value];
  }));
  if (!meta.id || !meta.revision) throw new Error(`${file} requires id and revision`);
  return { meta, markdown: match[2].trim() };
};
const welcome = await read('content/welcome.md');
const tips = []; const items = []; const resources = {};
for (const [folder, kind] of kinds) {
  const directory = `content/${folder}`;
  for (const name of (await fs.readdir(directory).catch(() => [])).filter(name => name.endsWith('.md')).sort()) {
    const content = await read(path.join(directory, name));
    if (kind === 'tip') tips.push({ id: content.meta.id, revision: content.meta.revision, markdown: content.markdown });
    else {
      if (!content.meta.title || !content.meta.publishedAt) throw new Error(`${name} requires title and publishedAt`);
      const uri = `mahayana://${plugin.name}/content/${folder}/${content.meta.id}`;
      resources[uri] = content.markdown;
      items.push({ id: content.meta.id, revision: content.meta.revision, kind, title: content.meta.title,
        publishedAt: content.meta.publishedAt, summary: content.meta.summary || undefined,
        expiresAt: content.meta.expiresAt || undefined, coverImage: content.meta.coverImage || undefined,
        tags: content.meta.tags || [], quickReplies: [], resourceUri: uri });
    }
  }
}
items.sort((a, b) => b.publishedAt.localeCompare(a.publishedAt) || a.id.localeCompare(b.id));
const source = JSON.stringify({ welcome, tips, items, resources });
const quickReplies = [
  { id: 'account-list', label: '查看 ChatGPT 账号', aliases: ['账号列表', '管理账号'], action: { type: 'tool', name: 'account_list', arguments: {} } },
  { id: 'account-add', label: '添加 ChatGPT 账号', aliases: ['添加账号', '登录新账号'], action: { type: 'tool', name: 'account_add', arguments: {} } },
  { id: 'account-login-link', label: '生成一次性登录链接', aliases: ['登录链接'], action: { type: 'tool', name: 'account_login_link', arguments: {} } },
  { id: 'account-status', label: '检查账号凭证状态', aliases: ['账号健康检查'], action: { type: 'tool', name: 'account_status', arguments: {} } },
  { id: 'sync-actions-credentials', label: '一键更新凭证到 GitHub Secrets', aliases: ['同步已登录凭证', '更新 Action 凭证', '一键更新凭证'], action: { type: 'tool', name: 'sync_actions_credentials', arguments: {} } },
  { id: 'login-and-sync-actions', label: '登录并同步 Action 凭证', aliases: [], action: { type: 'tool', name: 'login_and_sync_actions', arguments: {} } },
  { id: 'queue-status', label: '查看任务队列', aliases: [], action: { type: 'tool', name: 'queue_status', arguments: {} } },
  { id: 'start-actions-runner', label: '启动 6 小时 Action', aliases: [], action: { type: 'tool', name: 'start_actions_runner', arguments: {} } },
  { id: 'prompt-templates', label: '内置任务提示词', aliases: [], action: { type: 'tool', name: 'prompt_templates', arguments: {} } },
  { id: 'wait-review', label: '等待验收任务', aliases: [], action: { type: 'tool', name: 'wait_for_review', arguments: { timeout: 60 } } },
];
const home = { schema: 'mahayana.miniapp.home.v1', revision: crypto.createHash('sha256').update(`${source}:${JSON.stringify(quickReplies)}`).digest('hex'),
  app: { id: plugin.name, title: plugin.interface.displayName, version: plugin.version, source: plugin.repository },
  welcome: { id: welcome.meta.id, markdown: welcome.markdown }, tips, quickReplies,
  feed: { items: items.slice(0, 10), nextCursor: items.length > 10 ? '10' : null } };
if (Buffer.byteLength(JSON.stringify(home)) > 32768) throw new Error('home payload exceeds 32 KiB');
await fs.writeFile('worker/src/content.generated.ts', `export const HOME = ${JSON.stringify(home, null, 2)} as const;\nexport const RESOURCES: Record<string,string> = ${JSON.stringify(resources, null, 2)};\n`);
