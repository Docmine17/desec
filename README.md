# deSEC Dynamic DNS Client

A lightweight Bash client for updating [deSEC](https://desec.io/) dynamic DNS records. Supports multiple zones with independent configuration and automatic IPv6 address change detection.

> **Note:** This client is **IPv6-only**. It monitors dynamic IPv6 addresses on specified network interfaces and updates records via `update6.dedyn.io`. IPv4 is not supported.

## Features

- **Multi-zone support** — manage multiple domains, each with its own configuration file.
- **IP change detection** — tracks addresses per zone to avoid unnecessary API calls.
- **Safe configuration** — config files are parsed without shell evaluation; only expected keys are accepted.
- **Graceful shutdown** — handles `SIGTERM` and `SIGINT` for clean service termination.
- **Rate limiting** — spaces API calls between zones to respect deSEC rate limits.
- **Systemd integration** — includes a service unit for background operation.

## Requirements

- Bash 4.0+
- `curl`

## Installation

```bash
git clone https://github.com/Docmine17/desec.git
cd desec
chmod +x desec.sh
```

## Configuration

Zone configuration files are stored in the `zones/` directory. Each file defines a single zone and must use the `.conf` extension.

### Creating a zone

Copy the provided sample and edit it:

```bash
cp zones/domain.dedyn.io.sample zones/yourdomain.dedyn.io.conf
```

Each `.conf` file specifies the network interface, API token, and an optional IP selection mode on a single line separated by spaces:

```text
INTERFACE TOKEN [IP_TYPE]
```

Supported `IP_TYPE` values:
- `any` *(default)*: Uses any valid global IPv6 address available on the interface.
- `stable`: Uses only stable SLAAC (`00`) or static (`80`) addresses.
- `temporary`: Uses only dynamic privacy extension addresses (`01`).

Example (`zones/yourdomain.dedyn.io.conf`):

```text
eth0 your_desec_token_here stable
```

Use `ip -6 addr` to identify the correct interface.

## Usage

### Manual execution

```bash
./desec.sh
```

### Options

| Option       | Description                                        | Default              |
|--------------|----------------------------------------------------|----------------------|
| `--zone`     | Path to the directory containing `.conf` files.    | `<script_dir>/zones` |
| `--interval` | Check interval in seconds.                         | `20`                 |
| `-h, --help` | Show usage information.                            | —                    |

Examples:

```bash
# Custom config directory
./desec.sh --zone /etc/desec/zones/

# Check every 60 seconds
./desec.sh --interval 60

# Both options combined
./desec.sh --zone /etc/desec/zones/ --interval 60
```

### Running as a systemd service

1. Edit `desec-dns.service` and set the correct path in `ExecStart`:

   ```ini
   ExecStart=/bin/bash /path/to/desec.sh
   ```

2. Install and enable the service:

   ```bash
   sudo cp desec-dns.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now desec-dns.service
   ```

3. Check status:

   ```bash
   systemctl status desec-dns.service
   ```

## How it works

1. The script loads all `.conf` files from the configured zones directory.
2. For each zone, it reads the current dynamic IPv6 address from the specified interface.
3. If the address differs from the previously recorded one, it sends an update to the deSEC API.
4. The process repeats at the configured interval.

On receiving `SIGTERM` or `SIGINT`, the script logs the event and exits cleanly.

## License

[MIT](LICENSE)
