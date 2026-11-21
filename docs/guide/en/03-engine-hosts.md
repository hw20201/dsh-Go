# Remote hosts

dsh-Go connects to DSH on your computer or server. Chats, workspaces and plugins belong to the connected host. The current app has no phone-local engine installation, startup, Linux environment, reset or uninstall entry, and opening the app does not start a phone-local engine.

## First launch

The first time you open the app, connect to DSH on your computer or server without installing an engine on the phone.

## Switch hosts

Open the chat list and tap the host name at the bottom to open **Switch host**, then choose a saved remote host. With no hosts yet, tap **Connect a computer or server**; otherwise tap **Manage remote hosts**.

Tap the icon to the left of the host name for the current remote host's connection status and network path, with an on-demand latency measurement where supported.

<!-- nav: remoteSwitchHost,remoteManageHosts -->
`Switch host › Manage remote hosts` · [Open](dshgo://open/remote)

It is in Settings too:

<!-- nav: commonSettings,commonRemoteHost -->
`Settings › Remote host`

On launch, the app reconnects to the last host only when **Connect to the last host** is enabled. Turning it off keeps your saved hosts and lets you select one manually.

## Add an SSH host

The host needs SSH enabled and DSH installed (`npm i -g @deepseek-ai/dsh`).

1. On the remote hosts page, tap **Add SSH host**.
2. Enter the **Host** and **Username**. **Port** defaults to 22. The name is optional.
3. Sign in with a **Password** or a **Private key**. You can **Import from file**, and add a **Private key passphrase (optional)**. Passwords and keys stay on this phone.
4. **Instance management** defaults to **Managed**: **Start command** defaults to `dsh web`; if you installed DSH with nvm, enter its full path. For an instance you manage yourself, select **Attach only** and enter its **Remote DSH port** and **DSH launch token** from its launch URL. **Working directory (optional)** is where new chats start; use an absolute path in attach-only mode.
5. Tap **Test connection**. The first time, **Trust this host?** appears: check the fingerprint on the host, and tap **Trust and connect** if it matches.
6. Tap **Save**, then select the host in the list.

In managed mode, testing starts or reuses DSH on the host, and it keeps running afterwards. **Attach only** opens an SSH tunnel to the specified port on remote `127.0.0.1`. It never discovers instances, starts, stops or restarts DSH, or reads/writes managed state files. Start the instance yourself first and keep it running. If connection fails, check the port and token; the app never restarts it as a repair. The token stays in secure storage on this phone, like the SSH password and private key.

Managed mode refuses to replace a live instance whose start command differs or launch log is missing. A rejected token or refused reused port never authorizes a restart either. Check the settings or use **Attach only** first. If you really intend to replace the app-recorded instance, choose **Restart managed DSH** in the DSH section of Edit host and confirm. This may interrupt other clients and active chats; normal **Test connection** never performs it. Confirmed dead managed processes can still be started automatically.

**SSH compression** is on by default, negotiating compression after authentication. Unsupported servers continue uncompressed. Turn it off in the host form if needed; save and establish a new SSH connection to apply.

To change or delete a host, tap **Edit** next to it to open **Edit host**; **Delete this host** is at the bottom. Deleting removes only the settings, password, key and launch token saved on this phone; DSH and chats on the host stay.

## DSH Remote

No network setup, end-to-end encrypted. Good for computers on another network.

1. Install the remote plugin in the host's DSH and sign in.
2. On the remote hosts page, choose the same sign-in provider you used on that host, for example “Continue with GitHub”, and sign in with the same account. If the page lists no providers and shows only **Sign in in browser**, tap that button.
3. Select an online host. On first connection, check that the identity fingerprint matches the one the host's remote plugin shows, then tap **Trust and connect**.

When the server supports it, you can also choose **Pair a computer by scanning**: sign in to DeepSeek in the app, scan the code shown by the computer’s Remote plugin, check the computer fingerprint, then enter the verification code as prompted. Camera permission is only for capturing the QR code; reading an image from photos or pasting the pairing link still works without it. Opening the scanner initializes the shared ML Kit SDK on demand, without requiring or enabling phone control’s text recognition. See the [FAQ](11-faq.md#local-text-recognition-and-google-ml-kit) for SDK statistics disclosures.

Under DSH Remote's **Connection route** on the remote hosts page, choose **Automatic (recommended)** to try LAN / P2P, then TURN, then Relay; **Relay only** to skip WebRTC; or **Direct only (LAN / P2P)** to disallow TURN and Relay data paths. If direct-only cannot connect, switch to Automatic or Relay only. Direct-only still uses Relay for account authentication and connection signaling. This choice applies only to DSH Remote, not separate SSH or direct DSH address hosts. It takes effect on the next connection without closing the current one; **Reconnect using new route** asks for confirmation and may interrupt ongoing chats or operations. Network details distinguish the actual current path from the saved choice for the next connection and show connection time, available round-trip latency and fallback reason. WebRTC routes also show the selected ICE candidates' phone/Host IPv4 or IPv6 and UDP or TCP, never raw IP addresses. Unmeasured or unconfirmed values are not presented as known results.

<!-- nav: commonSettings,commonRemoteHost,remoteCompactHistory -->
`Settings › Remote host › Compact history`

**Compact history** is off by default. Supporting DSH Remote Hosts summarize historical tool arguments and output to reduce history transfer; message text, live replies, approvals and original Host records stay unchanged. Switch to another remote host and back, or restart the app, to apply. The current client and its automatic reconnects retain their original mode to avoid mixing cached history. After turning it off, select the host again and reopen the chat to load full history. Older Hosts continue sending full history; SSH is unaffected.

DSH Remote connects to one host at a time; switching disconnects the previous one. Over DSH Remote: you can send images only, plugins can only be turned on or off, and DS Bot and chat log export aren't available. Conversation backups use a separate session-transfer capability, not chat log export.

## Conversation backups and restore

<!-- nav: commonSettings,commonRemoteHost,backupTitle -->
`Settings › Remote host › Conversation backups`

This feature is available only for DSH Remote / Relay hosts. SSH and separate direct DSH address connections are not supported yet. The source host must advertise `session.transfer` export support, and the target must advertise import support; each is checked independently. Older plugins without the respective capability are identified.

Connect the source Remote host, select a workspace and either one conversation or **Entire workspace**, then tap **Back up to phone**. Switch to the target host, reopen this page, choose an existing target workspace and tap a local backup to restore. Backup transfers are limited to 8 MiB per conversation; an entire workspace is backed up one conversation at a time and does not bypass this limit.

Files and the catalog are encrypted in app-private storage, with the key protected by system secret storage. Uninstalling the app or clearing app data loses these backups. Only complete entries whose length and SHA-256 match are published; interrupting a batch keeps completed entries. Every restore creates a new conversation from the full history snapshot without overwriting existing conversations or merging later messages. Attachments, workspace source files and cross-session relationships are excluded.

If a commit disconnects or its outcome is unclear, **Restores to check** keeps the pending record. Connect to the original target with the original Remote device identity and tap **Check**. The server retains results for about five minutes; if unknown, inspect the target first. The app never automatically imports again. After checking, you can acknowledge and clear the pending record; another import may create a duplicate. If history was restored but not attached to the workspace, find the shown conversation ID instead of importing again. Deleting a local backup never deletes conversations on hosts.

Remote currently connects to one host at a time, so copying uses backup-to-phone followed by switching and restoring, rather than simultaneous host-to-host forwarding.
