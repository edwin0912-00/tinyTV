# tinyTV with Siri (iOS Shortcuts)

Siri talks to the tinyTV core on the core host. the core host runs it all the time, so this Mac can be off.

- Address: `https://<your-core-host>.<tailnet>.ts.net:8443`
- Works only inside the tailnet. Keep the Tailscale app on the iPhone connected (VPN on demand helps).
- No password: the tailnet is the lock.

## How to make one shortcut

1. Open **Shortcuts** on the iPhone. Tap **+**.
2. Add the action **Get Contents of URL**.
3. Paste the URL from the table below.
4. Tap the arrow next to the URL. Set **Method** to **POST**.
5. Set **Request Body** to **JSON**. Add the fields from the table (or none).
6. Name the shortcut with the phrase you will say, for example "TV pause".
7. Say "Hey Siri, TV pause".

The answer is the TV state as JSON. Siri does not read it out loud, unless you add **Show Result**.

## Recipes

| Say | URL | JSON body |
|---|---|---|
| "Play on TV" (share sheet) | `/api/open` | `url` (Text) = **Shortcut Input** |
| "TV pause" (pause or play) | `/api/cast/pause` | none |
| "Stop TV" | `/api/cast/stop` | none |
| "TV power" | `/api/power` | none |
| "TV volume" | `/api/volume` | `v` (Number) = **Ask for Number** |
| "TV mute" | `/api/key` | `key` (Text) = `KEY_MUTE` |
| "TV home" | `/api/key` | `key` (Text) = `KEY_HOME` |
| "TV OK" | `/api/key` | `key` (Text) = `KEY_OK` |
| "Mac screen on TV" | `/api/screen` | `from` (Text) = `mac` |
| "Core screen on TV" | `/api/screen` | `from` (Text) = `core` |
| "Movie light on" | `/api/movie` | `on` (Boolean) = true |
| "Movie light off" | `/api/movie` | `on` (Boolean) = false |

Each URL is the address plus the path, for example
`https://<your-core-host>.<tailnet>.ts.net:8443/api/cast/pause`.

### "Play on TV" from the share sheet

1. In the shortcut settings (the **i** button), turn on **Show in Share Sheet**.
2. Set it to accept **URLs** and **Text**.
3. In **Get Contents of URL**, set `url` to the magic variable **Shortcut Input**.
4. In YouTube or Safari, tap **Share › Play on TV**.

Links work for YouTube, most video pages, direct video files and magnet links.
"Mac screen on TV" needs tinyTV open on the Mac: the Mac sends its screen to the core host.

## Other keys

`/api/key` accepts names that start with `KEY_`. Checked on this TV:
`KEY_POWER KEY_OK KEY_UP KEY_DOWN KEY_LEFT KEY_RIGHT KEY_RETURNS KEY_HOME KEY_MENU KEY_PLAY KEY_MUTE`.

## Test from a computer in the tailnet

```bash
curl -X POST -H 'Content-Type: application/json' -d '{}' https://<your-core-host>.<tailnet>.ts.net:8443/api/cast/pause
```
