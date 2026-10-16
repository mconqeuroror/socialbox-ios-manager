import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const dirs = ['api', 'lib', 'scripts', 'tests', 'public'];
let count = 0;
for (const dir of dirs) for (const name of await readdir(dir)) if (/\.m?js$/.test(name)) {
  const result = spawnSync(process.execPath, ['--check', `${dir}/${name}`], { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status || 1); count++;
}
console.log(`Build passed: ${count} JavaScript modules checked; static assets ready.`);
