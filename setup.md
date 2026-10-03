# Learning Project: Node.js on AWS with a Custom VPC

Oct 3, 2026 · @ARPIT

You will build a tiny Node.js API, put it in a VPC you design yourself, and deploy it the same way as Fameo: GitHub builds and tests, then a self-hosted runner on the server deploys it. Plan on 3 to 4 hours; it costs almost nothing if you clean up at the end.

## What you'll build

&#91;embedded content: hello-aws architecture · VPC, two subnets, one server\]

The public subnet holds one server where nginx is the only open door; the private subnet shows what "unreachable from the internet" means. GitHub never connects in: your runner fetches each job over an outgoing connection. The finished project files are in the `hello-aws` folder in the chat.

## Part 1: Write the Node.js app (on your laptop)

A zero-dependency API with four routes and three tests. No Express, so `npm ci` has nothing to download and the focus stays on AWS. Install **Node.js 22 LTS** first (nodejs.org).

1. Create the folders:

```bash
mkdir hello-aws && cd hello-aws
mkdir src test deployment server
```

2. `package.json`:

```json
{
  "name": "hello-aws",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "start": "node src/server.js",
    "test": "node --test"
  }
}
```

3. `src/app.js` holds the routes, kept apart from the port so tests can start it on a random port:

```javascript
import http from 'node:http';

const notes = [{ id: 1, text: 'Hello from AWS' }];

const send = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

export const createApp = () =>
  http.createServer((req, res) => {
    const { pathname } = new URL(req.url, 'http://localhost');

    if (req.method === 'GET' && pathname === '/health') {
      return send(res, 200, { status: 'ok', commit: process.env.APP_COMMIT ?? 'dev' });
    }
    if (req.method === 'GET' && pathname === '/') {
      return send(res, 200, { message: 'Hello from my Node.js server on AWS!' });
    }
    if (req.method === 'GET' && pathname === '/api/notes') {
      return send(res, 200, notes);
    }
    if (req.method === 'POST' && pathname === '/api/notes') {
      let raw = '';
      req.on('data', (chunk) => (raw += chunk));
      req.on('end', () => {
        try {
          const { text } = JSON.parse(raw || '{}');
          if (typeof text !== 'string' || text.trim() === '') {
            return send(res, 400, { error: 'text is required' });
          }
          const note = { id: notes.length + 1, text: text.trim() };
          notes.push(note);
          return send(res, 201, note);
        } catch {
          return send(res, 400, { error: 'invalid JSON' });
        }
      });
      return;
    }
    return send(res, 404, { error: 'not found' });
  });
```

4. `src/server.js` starts it. It listens on `127.0.0.1` by default, so on the server only nginx can reach it:

```javascript
import { createApp } from './app.js';

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '127.0.0.1';

createApp().listen(port, host, () => {
  console.log(`hello-aws listening on http://${host}:${port}`);
});
```

5. `test/app.test.js` uses Node's built-in test runner:

```javascript
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';

let server;
let base;

before(async () => {
  server = createApp();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test('GET /health answers ok', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'ok');
});

test('POST /api/notes adds a note', async () => {
  const res = await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: 'learning VPCs' }),
  });
  assert.equal(res.status, 201);
  const list = await (await fetch(`${base}/api/notes`)).json();
  assert.ok(list.some((n) => n.text === 'learning VPCs'));
});

test('POST /api/notes rejects empty text', async () => {
  const res = await fetch(`${base}/api/notes`, { method: 'POST', body: '{}' });
  assert.equal(res.status, 400);
});
```

6. `.gitignore`:

```
node_modules/
.env
*.pem
release/
*.tar.gz
```

7. Try it:

```bash
npm install          # creates package-lock.json (the workflow's npm ci needs it)
npm test             # pass 3, fail 0
npm start            # then, in a second terminal:
curl http://127.0.0.1:3000/health
curl -X POST http://127.0.0.1:3000/api/notes -H 'Content-Type: application/json' -d '{"text":"hi"}'
```

Notes live in memory, so they reset on every restart. That is fine for learning; a database would be the next project.

## Part 2: Put it on GitHub

Make the repository **private**. A self-hosted runner runs whatever code a workflow sends it, and on a public repository a stranger's pull request could send it some.

1. GitHub → **New repository** → name `hello-aws` → **Private** → no README → **Create**.
2. Push your code:

```bash
git init
git add .
git commit -m "Hello AWS API with tests"
git branch -M main
git remote add origin https://github.com/<your-user>/hello-aws.git
git push -u origin main
```

3. **Settings → Environments → New environment** → name it `production` → **Deployment branches and tags → Selected branches** → add `main`. Only `main` can deploy from now on.

The workflow and deploy script are added in Part 7, once the server can receive them.

## Part 3: Build the VPC by hand

A VPC is your own private network inside AWS. You will build every piece yourself instead of using the default VPC, because that is where the learning is. All of it is free.

| Piece | What it does | Yours |
| --- | --- | --- |
| VPC | The whole private network and its address range | `hello-vpc`, `10.0.0.0/16` (65,536 addresses) |
| Public subnet | A slice of the VPC whose traffic can reach the internet | `hello-public-a`, `10.0.1.0/24` (251 usable; AWS keeps 5) |
| Private subnet | A slice with no route to the internet | `hello-private-a`, `10.0.2.0/24` |
| Internet gateway | The VPC's door to the internet | `hello-igw` |
| Route table | The signposts: where traffic for each address goes | `hello-public-rt`, `hello-private-rt` |
| Security group | A firewall around each server; it remembers replies (stateful) | `hello-web-sg`, `hello-private-sg` |
| Network ACL | A firewall around each subnet; checks both directions (stateless) | Left at the default (allow all) |

The one idea to remember: **a subnet is public only because its route table sends `0.0.0.0/0` to an internet gateway.** Nothing else makes it public.

Stay in one region for the whole project, e.g. **Asia Pacific (Mumbai) ap-south-1** (top-right menu).

### 3a. The VPC

1. **VPC console → Your VPCs → Create VPC.**
2. Choose **VPC only** (not "VPC and more"; you are building the rest by hand).
3. Name `hello-vpc`, IPv4 CIDR `10.0.0.0/16`, **No IPv6**, tenancy **Default** → **Create VPC**.
4. Select it → **Actions → Edit VPC settings** → tick **Enable DNS hostnames** → Save. Servers then get readable DNS names.

### 3b. Two subnets

**Subnets → Create subnet** → VPC `hello-vpc`, then add both in one go:

| Name | Availability Zone | IPv4 CIDR |
| --- | --- | --- |
| `hello-public-a` | `ap-south-1a` | `10.0.1.0/24` |
| `hello-private-a` | `ap-south-1a` | `10.0.2.0/24` |

Then select `hello-public-a` → **Actions → Edit subnet settings** → tick **Enable auto-assign public IPv4 address** → Save. Servers launched there get a public IP automatically; servers in the private subnet never do.

### 3c. Internet gateway

1. **Internet gateways → Create internet gateway** → name `hello-igw` → Create.
2. **Actions → Attach to VPC** → `hello-vpc` → Attach. It shows **Attached**.

### 3d. Route tables

The VPC came with a **main** route table holding one route, `10.0.0.0/16 → local`: every subnet can already talk to every other subnet inside the VPC. You make two of your own so the difference is visible.

**Public route table**

1. **Route tables → Create route table** → name `hello-public-rt`, VPC `hello-vpc` → Create.
2. **Routes → Edit routes → Add route**: destination `0.0.0.0/0`, target **Internet Gateway → `hello-igw`** → Save.
3. **Subnet associations → Edit subnet associations** → tick `hello-public-a` → Save.

**Private route table**

1. Create `hello-private-rt` in `hello-vpc`. Leave its routes alone: only `local`.
2. Associate it with `hello-private-a`.

Check: `hello-public-rt` has two routes (`local`, `0.0.0.0/0 → igw-…`); `hello-private-rt` has one.

### 3e. Security groups

**EC2 console → Security Groups → Create security group**, VPC `hello-vpc` for both (the VPC dropdown is easy to miss; the default VPC is preselected).

**`hello-web-sg`** (the app server):

| Type | Port | Source | Why |
| --- | --- | --- | --- |
| HTTP | 80 | `0.0.0.0/0` | Anyone can reach nginx |
| SSH | 22 | **My IP** | Only you can log in |

**`hello-private-sg`** (for the private-subnet experiment in Part 8):

| Type | Port | Source | Why |
| --- | --- | --- | --- |
| SSH | 22 | **Custom → `hello-web-sg`** | Only servers in the web group can log in |

Using a security group as the source, instead of an IP, is the normal AWS way to say "only my app servers may talk to this". Leave outbound rules at the default (all traffic) on both.

## Part 4: Launch the server in the public subnet

**EC2 → Instances → Launch instances:**

| Setting | Value |
| --- | --- |
| Name | `hello-web` |
| AMI | **Amazon Linux 2023**, 64-bit (x86) |
| Instance type | `t3.micro` (1 GB), or whichever type the console marks **Free tier eligible** for your account |
| Key pair | **Create new key pair** → `hello-aws`, RSA, `.pem`. It downloads once; keep it |
| Network settings → **Edit** | VPC `hello-vpc`, subnet `hello-public-a`, auto-assign public IP **Enable** |
| Firewall | **Select existing security group** → `hello-web-sg` |
| Storage | 10 GiB, gp3 |

**Launch instance**, wait until **Running** with **2/2 checks passed**, then open it and note two addresses:

- **Private IPv4**: something like `10.0.1.25`. It comes from your public subnet's range, `10.0.1.0/24`.
- **Public IPv4**: something like `13.233.x.x`. The internet gateway maps it to the private address. It changes if you stop and start the instance; that's fine for a learning project. An Elastic IP would keep it fixed.

Connect from your laptop:

```bash
mkdir -p ~/.ssh && mv ~/Downloads/hello-aws.pem ~/.ssh/ && chmod 400 ~/.ssh/hello-aws.pem
ssh -i ~/.ssh/hello-aws.pem ec2-user@<public-ip>
```

On Windows, use PowerShell: `ssh -i $HOME\Downloads\hello-aws.pem ec2-user@<public-ip>`.

Type `yes` at the fingerprint question. Once in, look at the network from the inside:

```bash
ip -4 addr show | grep inet      # only the 10.0.1.x address: the server never sees its public IP
curl -s https://checkip.amazonaws.com    # the public IP: the internet sees this one
```

That difference is the internet gateway doing address translation for you.

## Part 5: Prepare the server

Run everything here in the SSH session. Two Linux users keep jobs apart: **`deploy`** runs the GitHub runner and owns the release folders; **`app`** only runs the Node process and can't change any files.

1. Packages, Node.js 22 and swap (1 GB of RAM is tight while the runner unpacks a release):

```bash
sudo dnf install -y nginx git tar libicu
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
sudo dnf install -y nodejs
node -v                                   # v22.x

sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

2. Users and folders:

```bash
sudo useradd --system --create-home --shell /bin/bash deploy
sudo useradd --system --no-create-home --shell /sbin/nologin app
sudo usermod -aG systemd-journal deploy      # lets deploy read the app's logs

sudo install -d -o deploy -g deploy -m 755 /opt/hello-aws /opt/hello-aws/releases
sudo install -d -m 755 /etc/hello-aws
echo 'PORT=3000' | sudo tee /etc/hello-aws/app.env
sudo chmod 600 /etc/hello-aws/app.env
```

`app.env` is where secrets would go in a real project (one `KEY=value` per line). systemd reads it as root, so only root can see it.

3. The service. Create `/etc/systemd/system/hello-aws.service` with `sudo nano`:

```ini
[Unit]
Description=hello-aws Node.js API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=app
Group=app
WorkingDirectory=/opt/hello-aws/current
EnvironmentFile=/etc/hello-aws/app.env
Environment=NODE_ENV=production
# Expose the deployed commit at /health
ExecStart=/bin/sh -c 'export APP_COMMIT="$$(cat COMMIT 2>/dev/null)"; exec /usr/bin/node src/server.js'
Restart=always
RestartSec=3
MemoryMax=300M

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable hello-aws      # it starts on the first deploy, when /opt/hello-aws/current exists
```

4. Let `deploy` restart this one service, and nothing else, without a password:

```bash
echo 'deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart hello-aws' | sudo tee /etc/sudoers.d/hello-aws
sudo chmod 440 /etc/sudoers.d/hello-aws
sudo visudo -c                       # must end with: parsed OK
```

5. nginx in front of the app. Create `/etc/nginx/conf.d/hello-aws.conf`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo nginx -t && sudo systemctl enable --now nginx
curl -i http://localhost/            # 502 Bad Gateway for now: nginx works, the app isn't deployed yet
```

The app listens on `127.0.0.1:3000`, and port 3000 isn't in the security group anyway, so the only way in from outside is nginx on port 80. HTTPS needs a domain; add one later with certbot, as in the Fameo guide.

## Part 6: Install the GitHub self-hosted runner

The runner is a small GitHub program on your server. It opens an **outgoing** HTTPS connection to GitHub through the internet gateway and waits for jobs. Nothing comes in, so you never open a port for it.

1. GitHub → `hello-aws` → **Settings → Actions → Runners → New self-hosted runner** → **Linux**, **x64**. Keep the page open; it shows the commands and a one-time token (valid for about an hour).
2. On the server, switch to the `deploy` user and run the page's **Download** commands:

```bash
sudo -iu deploy
mkdir actions-runner && cd actions-runner
# paste the curl + tar lines from the GitHub page here
```

3. Register it with a label your workflow will ask for:

```bash
./config.sh --url https://github.com/<your-user>/hello-aws --token <TOKEN> \
  --name hello-web --labels hello-aws --unattended
exit
```

4. Install it as a service that runs as `deploy` and starts on boot:

```bash
cd /home/deploy/actions-runner
sudo ./svc.sh install deploy
sudo ./svc.sh start
sudo ./svc.sh status        # active (running)
```

Back on the GitHub Runners page, `hello-web` shows **Idle** with the labels `self-hosted`, `Linux`, `X64`, `hello-aws`.

## Part 7: The workflow, the deploy script and the first deploy

Same method as Fameo: GitHub's machine installs, tests and packs the code; your runner downloads exactly that package and swaps it in. Add both files to the repository.

1. `.github/workflows/deploy.yml`:

```yaml
name: Build, test and deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest          # GitHub's machine: build and test here, not on the server
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: actions/setup-node@v7
        with:
          node-version: '22'
      - name: Install
        run: npm ci --no-audit --no-fund
      - name: Test
        run: npm test
      - name: Package release
        shell: bash
        run: |
          set -euo pipefail
          mkdir release
          cp -R src package.json package-lock.json release/
          prohibited=$(find release -type f \( -name '.env*' -o -name '*.pem' -o -name '*.key' \) -print -quit)
          test -z "$prohibited" || { echo "Credential file found ($prohibited); refusing upload."; exit 1; }
          printf '%s\n' "$GITHUB_SHA" > release/COMMIT
          tar -czf "hello-aws-$GITHUB_SHA.tar.gz" -C release .
      - uses: actions/upload-artifact@v7
        with:
          name: hello-aws-${{ github.sha }}
          path: hello-aws-${{ github.sha }}.tar.gz
          if-no-files-found: error
          retention-days: 14

  deploy:
    name: Deploy to EC2
    needs: build
    if: github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')
    runs-on: [self-hosted, hello-aws]   # your runner on the server
    environment: production
    timeout-minutes: 10
    concurrency:
      group: production-deploy
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: actions/download-artifact@v7
        with:
          name: hello-aws-${{ github.sha }}
          path: release-artifact
      - name: Deploy
        run: bash deployment/deploy.sh "release-artifact/hello-aws-$GITHUB_SHA.tar.gz" "$GITHUB_SHA"
```

2. `deployment/deploy.sh` keeps one folder per release and points a `current` link at the live one, so switching versions is instant and the last 5 stay ready for rollback:

```bash
#!/usr/bin/env bash
# Deploys one tested release. Run on the server by the GitHub runner (user "deploy"):
#   bash deployment/deploy.sh <hello-aws-SHA.tar.gz> <40-char commit SHA>
#
#   /opt/hello-aws/releases/<sha>/   one folder per release (last 5 kept)
#   /opt/hello-aws/current           symlink to the live release
# If the new release fails its health check, the previous one is put back.
set -euo pipefail

ARCHIVE="${1:?usage: deploy.sh <archive.tar.gz> <commit-sha>}"
SHA="${2:?usage: deploy.sh <archive.tar.gz> <commit-sha>}"
APP_DIR="${APP_DIR:-/opt/hello-aws}"
SERVICE="${SERVICE:-hello-aws}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:3000/health}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

RELEASES="$APP_DIR/releases"
TARGET="$RELEASES/$SHA"
STAGING="$RELEASES/.staging-$SHA"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid commit SHA: $SHA"
[[ -f "$ARCHIVE" ]] || fail "archive not found: $ARCHIVE"
[[ -d "$RELEASES" ]] || fail "$RELEASES does not exist (see Part 5)"

# 1. Unpack, check, install production dependencies, move into place.
if [[ -d "$TARGET" ]]; then
  echo "Release $SHA is already on the server; reusing it."
else
  rm -rf "$STAGING"
  mkdir "$STAGING"
  tar -xzf "$ARCHIVE" -C "$STAGING" --no-same-owner
  [[ "$(cat "$STAGING/COMMIT" 2>/dev/null)" == "$SHA" ]] || { rm -rf "$STAGING"; fail "COMMIT file does not match $SHA"; }
  (cd "$STAGING" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
  mv "$STAGING" "$TARGET"
fi

PREVIOUS=""
[[ -L "$APP_DIR/current" ]] && PREVIOUS="$(readlink -f "$APP_DIR/current")"

switch_to() {
  ln -sfn "$1" "$APP_DIR/current.next"
  mv -Tf "$APP_DIR/current.next" "$APP_DIR/current"   # atomic swap of the symlink
  sudo -n /usr/bin/systemctl restart "$SERVICE"
}

healthy() {
  for _ in $(seq 1 15); do
    curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# 2. Switch, restart, check; roll back on failure.
echo "Deploying $SHA"
switch_to "$TARGET"
if healthy; then
  echo "Live: $(curl -fsS "$HEALTH_URL")"
else
  echo "Health check failed. Last log lines:" >&2
  journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null || true
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" && "$PREVIOUS" != "$TARGET" ]]; then
    echo "Rolling back to $(basename "$PREVIOUS")" >&2
    switch_to "$PREVIOUS"
    healthy && echo "Rollback succeeded." >&2 || echo "Rollback is unhealthy too; check the server." >&2
  fi
  exit 1
fi

# 3. Keep the newest releases; never delete the live one.
CURRENT_REAL="$(readlink -f "$APP_DIR/current")"
ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's:/*$::' | tail -n +"$((KEEP_RELEASES + 1))" |
  while read -r old; do
    [[ "$old" == "$CURRENT_REAL" ]] || rm -rf "$old"
  done
```

3. Push and watch the first deploy:

```bash
git add .github deployment
git commit -m "Add build and deploy workflow"
git push
```

GitHub → **Actions** → the run shows **build** (on GitHub's machine), then **Deploy to EC2** (on your runner). The deploy log ends with `Live: {"status":"ok","commit":"…"}`.

4. Check from your laptop's browser or terminal:

```bash
curl http://<public-ip>/health          # the commit you just pushed
curl http://<public-ip>/api/notes
```

5. See the pull-request path: create a branch, change the message in `src/app.js`, open a pull request into `main`. Only **build** runs. Merge it, and **Deploy to EC2** follows; `/` returns the new message within a minute.

On the server, `ls -l /opt/hello-aws/releases` shows one folder per deploy and `readlink /opt/hello-aws/current` shows the live one.

## Part 8: Experiments that show how the VPC works

Each one breaks a single piece on purpose, so you see what that piece does. Put each one back before starting the next.

### 1. Take away the internet route

In `hello-public-rt` → **Routes → Edit routes**, remove `0.0.0.0/0` and save.

- `curl http://<public-ip>/health` from your laptop hangs.
- Your SSH session freezes.
- Within a minute, the runner shows **Offline** in GitHub.

The server is still running; it just has no way out. **Lesson:** the route table, not the subnet's name, decides what is public. Add the route back and everything returns.

### 2. Close a port in the security group

In `hello-web-sg`, delete the HTTP (80) rule. `curl` now **times out** instead of saying "connection refused": a security group drops blocked traffic silently. Add the rule back.

While you're there, notice that you never allowed the *replies* back in. Security groups are **stateful**: a reply to an allowed request is always let through.

### 3. Meet a stateless firewall (network ACL)

1. **VPC → Network ACLs → Create network ACL** → `hello-public-nacl`, VPC `hello-vpc`.
2. **Subnet associations** → associate `hello-public-a`. Everything stops: a new ACL denies all traffic until you add rules.
3. **Inbound rules** → rule 100: HTTP 80 from `0.0.0.0/0`; rule 110: SSH 22 from your IP (`x.x.x.x/32`). The site still fails.
4. **Outbound rules** → rule 100: Custom TCP, ports `1024-65535`, to `0.0.0.0/0`. Now it works.

Unlike a security group, an ACL is **stateless**: replies go back out to the visitor's temporary ("ephemeral") port, and the ACL needs its own rule for that. Even now the runner goes **Offline**: its outgoing HTTPS to GitHub (port 443) isn't allowed out by these rules. When done, re-associate `hello-public-a` with the VPC's default ACL and delete `hello-public-nacl`.

### 4. A server in the private subnet

1. Launch a second instance: name `hello-private`, Amazon Linux 2023, `t3.micro`, key `hello-aws`, VPC `hello-vpc`, subnet **`hello-private-a`**, auto-assign public IP **Disable**, security group **`hello-private-sg`**.
2. It has only a `10.0.2.x` address, so you can't reach it from your laptop. Jump through the public server instead (the key must be in your SSH agent):

```bash
ssh-add ~/.ssh/hello-aws.pem
ssh -J ec2-user@<public-ip> ec2-user@<private-ip>
```

3. From the private server, try:

```bash
curl -s http://10.0.1.<web-server>/health                  # works: the local route connects the subnets
curl -m 5 https://checkip.amazonaws.com || echo "no internet"  # fails: no route out
```

That second failure is the point of a private subnet: databases and internal services live there, unreachable from the internet. When they need to *call out* (updates, APIs), you add a **NAT gateway** in the public subnet and a `0.0.0.0/0 → nat-…` route in `hello-private-rt`. A NAT gateway is billed by the hour plus data, so for this project just read about it, or create one and delete it within the hour.

Terminate `hello-private` when you're done.

### 5. Watch the automatic rollback

Push a commit that breaks startup, e.g. add `process.exit(1);` as the first line of `src/server.js`. The deploy job fails its health check, prints the service log, puts the previous release back and ends red. `curl http://<public-ip>/health` keeps working the whole time. Revert the commit and push.

To roll back by hand on the server:

```bash
ls -t /opt/hello-aws/releases
sudo -u deploy ln -sfn /opt/hello-aws/releases/<older-sha> /opt/hello-aws/current
sudo systemctl restart hello-aws
```

## Part 9: Clean up so nothing keeps charging

The VPC, subnets, route tables, internet gateway, security groups and ACLs are free. What costs money while it exists:

| Item | Rough cost while it exists | Free tier |
| --- | --- | --- |
| `t3.micro` instance, running | about $0.01 an hour | Covered on most free-tier plans |
| Public IPv4 address (attached or Elastic) | $0.005 an hour, about $3.60 a month | Partly covered on some plans |
| 10 GiB gp3 disk | under $1 a month | Covered up to 30 GiB on most plans |
| NAT gateway, if you made one | a few cents an hour plus data | Not covered |

Prices are approximate; check **Billing → Bills** after a day to see what you're really paying.

To pause and keep everything, **stop** the instance (the disk stays and costs a little, and the public IP changes when you start it again). To finish, delete in this order, because each step frees something the next one needs:

1. **EC2 → Instances** → terminate `hello-web` (and `hello-private` if it's still there). Wait for **Terminated**.
2. If you made a NAT gateway or an Elastic IP: delete the NAT gateway, then **Elastic IPs → Release**.
3. **Security Groups** → delete `hello-private-sg` first (it points at `hello-web-sg`), then `hello-web-sg`.
4. **VPC → Your VPCs** → select `hello-vpc` → **Actions → Delete VPC**. The console lists the subnets, route tables, internet gateway and ACLs it will remove with it → confirm.
5. **EC2 → Key pairs** → delete `hello-aws` (and the `.pem` on your laptop, if you won't reuse it).
6. GitHub → **Settings → Actions → Runners** → `hello-web` → **Remove**.

One more safety net while learning: **Billing → Budgets → Create budget → Zero spend budget** emails you the moment anything starts costing money.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| Can't find `hello-vpc` when launching or creating a security group | The VPC dropdown still shows the default VPC; change it. Also check the region menu |
| SSH or `curl` times out | Check, in order: the instance has a public IP; `hello-public-rt` has `0.0.0.0/0 → igw`; the subnet is associated with that route table; the security group allows the port from your IP; the subnet uses the default ACL |
| SSH: `Permission denied (publickey)` | Log in as `ec2-user`, use the `.pem` chosen at launch, and run `chmod 400` on it |
| SSH stops working a day later | Your home IP changed: edit the SSH rule in `hello-web-sg` → Source **My IP** |
| `curl http://<ip>/` gives **502 Bad Gateway** | nginx works but the app is down: `sudo systemctl status hello-aws` and `sudo journalctl -u hello-aws -n 50` |
| You see the nginx welcome page | Your `hello-aws.conf` isn't in `/etc/nginx/conf.d/`, or nginx wasn't reloaded: `sudo nginx -t && sudo systemctl reload nginx` |
| Deploy job stays **Queued** | The runner is offline or the label doesn't match: GitHub → Settings → Actions → Runners must show `hello-web` **Idle** with label `hello-aws`; on the server, `sudo ./svc.sh status` in `/home/deploy/actions-runner` |
| Deploy fails: `sudo: a password is required` | The sudoers line is missing or names a different service: redo Part 5 step 4 |
| Deploy fails: `/opt/hello-aws/releases does not exist` | Part 5 step 2 wasn't run, or the folder isn't owned by `deploy` |
| Deploy fails: `npm: command not found` | Node.js isn't installed for all users: redo Part 5 step 1, then `sudo ./svc.sh stop && sudo ./svc.sh start` |
| Health check fails, rolls back | The app crashed on start: read the log lines printed in the deploy job |
| `/health` shows an old commit | The deploy job didn't run (pull-request builds never deploy), or it rolled back |
| Private server can't reach the internet | Expected: no NAT gateway. That's what a private subnet is |
