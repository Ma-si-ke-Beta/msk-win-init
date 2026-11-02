# msk-win-init

One-shot setup script for a fresh Windows Server (2019+):

1. OpenSSH Server (install, auto-start, firewall rule for TCP 22)
2. Passwordless SSH login for Administrators (public key in `administrators_authorized_keys`)
3. PowerShell 7 (latest stable) + set as the SSH default shell
4. Google Chrome (enterprise MSI)

Every installer is downloaded from the official source and its Authenticode signature is verified before install. Safe to re-run: finished steps are skipped.

## Usage

On the new server, open **PowerShell as Administrator** and run:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ma-si-ke-beta/msk-win-init/main/init-server.ps1 | iex
```

Then from your PC:

```
ssh Administrator@<server-ip>
```

Remember to allow inbound TCP 22 in your cloud provider's security group.

## Customize

Edit the config block at the top of `init-server.ps1`:

- `$PublicKeys` - public keys allowed to log in
- `$InstallPwsh` / `$InstallChrome` - toggle optional steps
