const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
let result = '', inStr = false, inLC = false, inBC = false, i = 0;
while (i < content.length) {
  const c = content[i], n = content[i + 1];
  if (inLC) { if (c === '\n') { inLC = false; result += '\n'; } i++; }
  else if (inBC) { if (c === '*' && n === '/') { inBC = false; i += 2; } else i++; }
  else if (inStr) {
    if (c === '\\') { result += c + n; i += 2; }
    else { if (c === '"') inStr = false; result += c; i++; }
  } else {
    if (c === '"') { inStr = true; result += c; i++; }
    else if (c === '/' && n === '/') { inLC = true; i += 2; }
    else if (c === '/' && n === '*') { inBC = true; i += 2; }
    else { result += c; i++; }
  }
}
result = result.replace(/,(\s*[}\]])/g, '$1');
process.stdout.write(JSON.stringify(JSON.parse(result), null, 2));
