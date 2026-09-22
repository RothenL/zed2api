# zed2api-auth — Windows desktop authorization tool

A standalone Windows console program that performs the Zed/GitHub OAuth login flow
and writes `accounts.json`. You run this on a Windows machine that can sign in to
Zed, then upload the resulting file to your zed2api server through its Web UI.

This is the **authorization** half of zed2api; the Linux/Docker server has no OAuth
flow of its own — it consumes the credential file this tool produces.

## Why a separate program?

The zed2api server runs on headless Linux (often in Docker) where launching a
browser and listening for an OAuth callback on `127.0.0.1:<port>` is impractical.
Authorization needs:

- a GUI environment to open the GitHub login page,
- RSA key generation + OAEP-SHA256 decryption of the returned token,
- a localhost callback server reachable by the user's browser.

All of that is easy on Windows with BCrypt + the default browser, and painful on
a Linux server. So we split it out: authenticate here, upload the file there.

## Build

Requires [Zig 0.15.x](https://ziglang.org/download/) on Windows.

```powershell
zig build
```

Produces `zig-out/bin/zed2api-auth.exe`.

## Usage

```powershell
.\zed2api-auth.exe [account-name]
```

- Opens a private/incognito browser window to the Zed native-app sign-in page.
- Waits for the OAuth callback on a random localhost port.
- Decrypts the returned access token, validates it, and writes `accounts.json` in
  the current directory.

If `[account-name]` is omitted, the GitHub user id is used as the key.

## Notes

- Windows only. On other platforms, log in via Zed itself and locate its
  `accounts.json`, or build the original zed2api binary and use its `login` flow on
  a machine that has a desktop.
- The generated `accounts.json` matches the format zed2api expects (see
  `accounts.example.json` in the repo root).
