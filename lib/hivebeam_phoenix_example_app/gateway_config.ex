defmodule HivebeamPhoenixExampleApp.GatewayConfig do
  @moduledoc false

  @default_base_url "http://127.0.0.1:8080"
  @default_provider "codex"
  @default_approval_mode "ask"
  @default_request_timeout_ms 30_000
  @default_ws_reconnect_ms 1_000
  @default_poll_interval_ms 500

  @spec require_token!() :: :ok
  def require_token! do
    case token() do
      nil -> raise "HIVEBEAM_GATEWAY_TOKEN is required"
      _value -> :ok
    end
  end

  @spec token() :: String.t() | nil
  def token do
    case System.get_env("HIVEBEAM_GATEWAY_TOKEN") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @spec base_url() :: String.t()
  def base_url do
    System.get_env("HIVEBEAM_GATEWAY_BASE_URL", @default_base_url)
    |> String.trim()
    |> case do
      "" -> @default_base_url
      value -> String.trim_trailing(value, "/")
    end
  end

  @spec default_provider() :: String.t()
  def default_provider do
    System.get_env("HIVEBEAM_DEFAULT_PROVIDER", @default_provider)
    |> normalize_provider()
  end

  @spec default_cwd() :: String.t()
  def default_cwd do
    case System.get_env("HIVEBEAM_DEFAULT_CWD") do
      nil ->
        File.cwd!()

      value ->
        case String.trim(value) do
          "" -> File.cwd!()
          path -> Path.expand(path)
        end
    end
  end

  @spec default_approval_mode() :: String.t()
  def default_approval_mode do
    System.get_env("HIVEBEAM_DEFAULT_APPROVAL_MODE", @default_approval_mode)
    |> normalize_approval_mode()
  end

  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms do
    parse_pos_integer(
      System.get_env("HIVEBEAM_CLIENT_REQUEST_TIMEOUT_MS"),
      @default_request_timeout_ms
    )
  end

  @spec ws_reconnect_ms() :: pos_integer()
  def ws_reconnect_ms do
    parse_pos_integer(System.get_env("HIVEBEAM_CLIENT_WS_RECONNECT_MS"), @default_ws_reconnect_ms)
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    parse_pos_integer(
      System.get_env("HIVEBEAM_CLIENT_POLL_INTERVAL_MS"),
      @default_poll_interval_ms
    )
  end

  @spec client_opts(String.t(), String.t() | nil, String.t() | nil) :: keyword()
  def client_opts(provider, cwd, approval_mode) do
    [
      base_url: base_url(),
      token: token(),
      provider: normalize_provider(provider || default_provider()),
      cwd: cwd || default_cwd(),
      approval_mode: normalize_approval_mode(approval_mode || default_approval_mode()),
      request_timeout_ms: request_timeout_ms(),
      ws_reconnect_ms: ws_reconnect_ms(),
      poll_interval_ms: poll_interval_ms()
    ]
  end

  @spec create_session_attrs(String.t(), String.t() | nil, String.t() | nil) :: map()
  def create_session_attrs(provider, cwd, approval_mode) do
    %{
      "provider" => normalize_provider(provider || default_provider()),
      "cwd" => cwd || default_cwd(),
      "approval_mode" => normalize_approval_mode(approval_mode || default_approval_mode())
    }
  end

  @spec normalize_provider(term()) :: String.t()
  def normalize_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "claude" -> "claude"
      _ -> "codex"
    end
  rescue
    _ ->
      @default_provider
  end

  @spec normalize_approval_mode(term()) :: String.t()
  def normalize_approval_mode(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "allow" -> "allow"
      "deny" -> "deny"
      _ -> "ask"
    end
  rescue
    _ ->
      @default_approval_mode
  end

  defp parse_pos_integer(nil, default), do: default

  defp parse_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_pos_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_pos_integer(_value, default), do: default
end
