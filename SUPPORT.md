# Getting Support

Need a hand getting TypMic running? Here's where to look.

## 1. Check the diagnostics first

On startup the server prints a detailed diagnostic block (IP / ffmpeg / certificate / port / API-key status). Most "can't connect" problems are visible there. The PC status page at `https://localhost:8443/desktop` also shows live connection state.

## 2. Common quick checks

- **Phone shows "connection refused / ERR_CONNECTION_REFUSED"** → the firewall step was skipped. On Windows re-run `allow_firewall.bat` as administrator; on macOS allow Python in the firewall; on Linux `sudo ufw allow 8443`.
- **iPhone shows a cert warning even after installing `rootCA.pem`** → you must also enable **Full Trust** at `Settings → General → About → Certificate Trust Settings`. Installing the profile alone is not enough.
- **Android shows "not secure"** → tap "Advanced → Proceed". This is expected for a self-signed cert.
- **No transcription appears** → verify `MIMO_API_KEY` is set in `.env` and that the PC has internet access to the MiMo endpoint.

## 3. Still stuck?

- Open a [GitHub Issue](https://github.com/DJKING792/TypMic/issues) with your OS, Python version, and the diagnostic output.
- For security-sensitive problems, follow [SECURITY.md](SECURITY.md) instead of a public issue.

TypMic is maintained in spare time, so responses may take a few days — thank you for your patience.
