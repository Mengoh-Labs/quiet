"""Fetch a hash-verified Ollama model into Quiet's separate benchmark store."""
import hashlib, json, pathlib, urllib.request
root = pathlib.Path.home() / 'Library/Application Support/ai.quandrylabs.quiet/BenchmarkOllama'
url = 'https://registry.ollama.ai/v2/library/qwen2.5/manifests/0.5b-instruct-q4_K_M'
request = urllib.request.Request(url, headers={'Accept': 'application/vnd.docker.distribution.manifest.v2+json'})
raw = urllib.request.urlopen(request, timeout=60).read()
manifest = json.loads(raw)
(root / 'blobs').mkdir(parents=True, exist_ok=True)
for item in [manifest['config'], *manifest['layers']]:
    digest = item['digest']
    assert digest.startswith('sha256:') and len(digest) == 71
    path = root / 'blobs' / digest.replace(':', '-')
    if not path.exists():
        partial = path.with_suffix('.partial')
        with urllib.request.urlopen('https://registry.ollama.ai/v2/library/qwen2.5/blobs/' + digest, timeout=90) as response, partial.open('wb') as output:
            while block := response.read(1024 * 1024): output.write(block)
        assert partial.stat().st_size == item['size']
        assert hashlib.file_digest(partial.open('rb'), 'sha256').hexdigest() == digest[7:]
        partial.rename(path)
    assert path.stat().st_size == item['size']
    assert hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == digest[7:]
    print(item['mediaType'], item['size'], digest, flush=True)
folder = root / 'manifests/registry.ollama.ai/library/qwen2.5'
folder.mkdir(parents=True, exist_ok=True)
(folder / '0.5b-instruct-q4_K_M').write_bytes(raw)
(root / 'source.json').write_text(json.dumps({'url': url, 'manifest_sha256': hashlib.sha256(raw).hexdigest()}, indent=2))
