# Buzzer relay

A tiny Go service that delivers remote push notifications to the Buzzer app via
APNs. It holds your APNs auth key + the set of registered device tokens, and
exposes one HTTP endpoint you can hit from webhooks, cron jobs, or any other
process: `POST /notify`.

```
webhook / curl / process ──POST /notify──▶ relay ──apns2──▶ APNs ──▶ your device
Buzzer app ──POST /register {token}──▶ relay (remembers the device)
```

## Setup

1. In the [Apple Developer portal](https://developer.apple.com/account/resources/authkeys/list),
   create an **APNs Auth Key** (Keys → +, enable "Apple Push Notifications service").
   Download the `.p8` file (you only get one download). Note its **Key ID**.
2. Note your **Team ID** (Membership page).
3. Keep the `.p8` somewhere outside the repo, or rely on `.gitignore` (it ignores
   `*.p8` and `tokens.json`). **Never commit the key.**

## Run

```sh
cd server
APNS_KEY_PATH=/path/to/AuthKey_ABC123DEFG.p8 \
APNS_KEY_ID=ABC123DEFG \
APNS_TEAM_ID=DEF123GHIJ \
go run .
```

| Env var          | Default                     | Notes |
|------------------|-----------------------------|-------|
| `APNS_KEY_PATH`  | —                           | Path to the `.p8` auth key (required for `/notify`). |
| `APNS_KEY_ID`    | —                           | Key ID from the dev portal. |
| `APNS_TEAM_ID`   | —                           | Apple developer Team ID. |
| `APNS_TOPIC`     | `com.melissaefoster.Buzzer` | Bundle id of the app. |
| `APNS_ENV`       | *(empty → sandbox)*         | `production` for App Store / TestFlight builds; anything else → **sandbox**. |
| `LISTEN_ADDR`    | `:8080`                     | Address to listen on. |
| `TOKENS_FILE`    | `tokens.json`               | Where registered device tokens are persisted. |
| `BUZZER_TOKEN`   | *(empty → open)*            | Bearer token required on `/register` + `/notify`. **Set this before exposing the relay.** |

## Auth

When `BUZZER_TOKEN` is set, `/register` and `/notify` require `Authorization: Bearer <token>`
(constant-time compared); `/health` stays open. When it's unset the relay runs open and
logs a warning — fine for localhost only.

The Buzzer app sends this token via the "Auth token" field in its Relay section. For server
processes / webhooks, add the header to the request (see examples below).

**Behind Traefik:** terminate TLS at Traefik and route to the relay; keep `BUZZER_TOKEN` set
too, so a proxy misconfig can't expose an open `/notify`. `GET /health` is unauthenticated for
uptime checks.

> **Sandbox vs production:** debug builds installed from Xcode produce *sandbox*
> device tokens and only work in sandbox mode (the default). If you push to a
> sandbox token in production mode (or vice versa) APNs returns `BadDeviceToken`.
> The relay does **not** prune tokens on `BadDeviceToken` (it's usually an
> environment mismatch, not a dead device) — only on `Unregistered` (410).

## Endpoints

### `POST /register`
Called by the app when APNs hands it a device token.
```sh
curl -X POST localhost:8080/register \
  -H 'content-type: application/json' \
  -d '{"token":"<hex device token>","platform":"ios"}'
```

### `POST /notify`
The webhook / automation entry point. Fans out to every registered device
(or just one if you pass `token`).
```sh
curl -X POST localhost:8080/notify \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'content-type: application/json' \
  -d '{"title":"Buzz","body":"it works"}'
```

All fields (only `title`/`body` — at least one — are required):

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | First line. |
| `subtitle` | string | Second line. |
| `body` | string | Main text. |
| `sound` | string | Default `"default"`; or a custom sound file name. |
| `badge` | int | App icon badge count. |
| `threadId` | string | Groups related notifications in the stack. |
| `interruptionLevel` | string | `passive` \| `active` \| `time-sensitive` \| `critical`. `time-sensitive` breaks through Focus (app has the entitlement); `critical` needs Apple approval. |
| `url` | string | The app opens this URL when the notification is **tapped**. |
| `data` | object | Arbitrary extra custom keys delivered to the app as `userInfo`. |
| `token` | string | Target one device instead of fanning out to all. |

Rich example:
```sh
curl -X POST localhost:8080/notify \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'content-type: application/json' \
  -d '{"title":"Build done","subtitle":"CI · main","body":"Tap to view the run",
       "url":"https://ci.example.com/run/123","threadId":"ci",
       "interruptionLevel":"time-sensitive"}'
```

### `GET /health`
```sh
curl localhost:8080/health
# {"ok":true,"tokens":1,"pusherReady":true,"env":"sandbox","topic":"com.melissaefoster.Buzzer"}
```

## Local app-side testing (no APNs round trip)

`payload.example.apns` is for delivering a notification straight to the iOS
Simulator via `simctl`, which exercises the app's notification handling without
touching APNs or this relay:
```sh
xcrun simctl push booted com.melissaefoster.Buzzer payload.example.apns
```
