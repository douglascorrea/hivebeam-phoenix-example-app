# Hivebeam Phoenix Example App

Phoenix LiveView example app that chats with Hivebeam agents through:
- Hivebeam gateway (`/v1`)
- Elixir SDK (`hivebeam-client-elixir`) as a local path dependency

The UI is a three-panel chat layout:
- left: session inspector
- center: timeline + composer + inline approval cards
- right: thread history

## Requirements

- Elixir/Erlang compatible with your local setup
- Gateway repo checked out at `/Volumes/corsair_1tb_mac/Sites/hivebeam`
- SDK repo checked out at `/Volumes/corsair_1tb_mac/Sites/hivebeam-client-elixir`

This project depends on the SDK via:

```elixir
{:hivebeam_client, path: "../hivebeam-client-elixir"}
```

## Environment Variables

- `HIVEBEAM_GATEWAY_BASE_URL` (default `http://127.0.0.1:8080`)
- `HIVEBEAM_GATEWAY_TOKEN` (required)
- `HIVEBEAM_DEFAULT_PROVIDER` (default `codex`)
- `HIVEBEAM_DEFAULT_CWD` (default `File.cwd!()`)
- `HIVEBEAM_DEFAULT_APPROVAL_MODE` (default `ask`)
- `HIVEBEAM_CLIENT_REQUEST_TIMEOUT_MS` (default `30000`)
- `HIVEBEAM_CLIENT_WS_RECONNECT_MS` (default `1000`)
- `HIVEBEAM_CLIENT_POLL_INTERVAL_MS` (default `500`)

## Run

```bash
mix setup
HIVEBEAM_GATEWAY_TOKEN=your-token mix phx.server
```

Open [http://localhost:4000/chat](http://localhost:4000/chat).

## Tests

```bash
mix format --check-formatted
mix compile --warnings-as-errors
HIVEBEAM_GATEWAY_REPO=../hivebeam HIVEBEAM_FAKE_ACP_CMD=../hivebeam-client-elixir/test/support/fake_acp mix test
```

Integration smoke (`test/integration/chat_gateway_integration_test.exs`) boots a real gateway process and uses the deterministic fake ACP command from:

- `/Volumes/corsair_1tb_mac/Sites/hivebeam-client-elixir/test/support/fake_acp`

You can override paths with:
- `HIVEBEAM_GATEWAY_REPO`
- `HIVEBEAM_FAKE_ACP_CMD`
