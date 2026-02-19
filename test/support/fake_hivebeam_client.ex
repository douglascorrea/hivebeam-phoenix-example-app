defmodule HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient do
  @moduledoc false
  use GenServer

  alias HivebeamClient.Event

  @type state :: %{
          owner: pid(),
          provider: String.t(),
          gateway_session_key: String.t() | nil,
          seq: non_neg_integer(),
          pending_approval: %{approval_ref: String.t(), request_id: String.t()} | nil,
          connected?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec create_session(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def create_session(server, attrs \\ %{}) when is_map(attrs) do
    GenServer.call(server, {:create_session, attrs})
  end

  @spec attach(GenServer.server(), String.t() | keyword()) :: {:ok, map()} | {:error, term()}
  def attach(server, arg), do: GenServer.call(server, {:attach, arg})

  @spec prompt(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prompt(server, request_id, text, _opts \\ [])
      when is_binary(request_id) and is_binary(text) do
    GenServer.call(server, {:prompt, request_id, text})
  end

  @spec cancel(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(server, _opts \\ []), do: GenServer.call(server, :cancel)

  @spec approve(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def approve(server, approval_ref, decision, _opts \\ [])
      when is_binary(approval_ref) and is_binary(decision) do
    GenServer.call(server, {:approve, approval_ref, decision})
  end

  @spec close(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(server, _opts \\ []), do: GenServer.call(server, :close)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    provider = normalize_provider(Keyword.get(opts, :provider, "codex"))

    {:ok,
     %{
       owner: owner,
       provider: provider,
       gateway_session_key: nil,
       seq: 0,
       pending_approval: nil,
       connected?: false
     }}
  end

  @impl true
  def handle_call({:create_session, attrs}, _from, state) do
    provider = normalize_provider(attrs["provider"] || attrs[:provider] || state.provider)
    session_key = "fake_session_" <> random_suffix()

    payload = %{
      "provider" => provider,
      "gateway_session_key" => session_key
    }

    {:reply, {:ok, payload}, %{state | provider: provider, gateway_session_key: session_key}}
  end

  def handle_call({:attach, arg}, _from, state) do
    case attach_session_key(arg, state) do
      nil ->
        {:reply, {:error, :gateway_session_key_required}, state}

      session_key ->
        unless state.connected? do
          send(state.owner, {:hivebeam_client, :connected, %{transport: "fake"}})
        end

        payload = %{
          "gateway_session_key" => session_key,
          "events" => [],
          "next_after_seq" => state.seq
        }

        {:reply, {:ok, payload},
         %{state | gateway_session_key: session_key, connected?: true, pending_approval: nil}}
    end
  end

  def handle_call({:prompt, request_id, text}, _from, state) do
    state =
      state
      |> emit_event("prompt_enqueued", %{"request_id" => request_id})
      |> emit_event("prompt_started", %{"request_id" => request_id})

    cond do
      String.contains?(String.downcase(text), "approval") ->
        approval_ref = "apr_" <> random_suffix()

        state =
          state
          |> emit_event("approval_requested", %{
            "request_id" => request_id,
            "approval_ref" => approval_ref,
            "request" => %{
              "tool_name" => "fake_tool",
              "summary" => "Approval required for fake action"
            }
          })
          |> Map.put(:pending_approval, %{approval_ref: approval_ref, request_id: request_id})

        {:reply, {:ok, %{"accepted" => true}}, state}

      true ->
        state =
          state
          |> emit_event("stream_update", %{
            "request_id" => request_id,
            "update" => %{"text" => "fake-client: #{text}"}
          })
          |> emit_event("stream_done", %{"request_id" => request_id})
          |> emit_event("prompt_completed", %{"request_id" => request_id})

        {:reply, {:ok, %{"accepted" => true}}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    request_id = state.pending_approval && state.pending_approval.request_id
    state = emit_event(state, "cancel_requested", %{"request_id" => request_id})
    {:reply, {:ok, %{"accepted" => true}}, state}
  end

  def handle_call({:cancel, _opts}, from, state) do
    handle_call(:cancel, from, state)
  end

  def handle_call({:approve, approval_ref, decision}, _from, state) do
    decision = normalize_decision(decision)

    case state.pending_approval do
      %{approval_ref: ^approval_ref, request_id: request_id} ->
        state =
          state
          |> emit_event("approval_resolved", %{
            "approval_ref" => approval_ref,
            "decision" => decision,
            "request_id" => request_id
          })
          |> emit_approval_completion(request_id, decision)
          |> Map.put(:pending_approval, nil)

        {:reply, {:ok, %{"accepted" => true}}, state}

      _ ->
        {:reply, {:error, :approval_not_found}, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = emit_event(state, "session_closed", %{})

    if state.connected? do
      send(state.owner, {:hivebeam_client, :disconnected, :closed})
    end

    {:reply, {:ok, %{"closed" => true}},
     %{state | connected?: false, gateway_session_key: nil, pending_approval: nil}}
  end

  def handle_call({:close, _opts}, from, state) do
    handle_call(:close, from, state)
  end

  defp emit_approval_completion(state, request_id, "allow") do
    state
    |> emit_event("stream_update", %{
      "request_id" => request_id,
      "update" => %{"text" => "fake-client: approval allowed"}
    })
    |> emit_event("stream_done", %{"request_id" => request_id})
    |> emit_event("prompt_completed", %{"request_id" => request_id})
  end

  defp emit_approval_completion(state, request_id, _decision) do
    emit_event(state, "prompt_failed", %{
      "request_id" => request_id,
      "reason" => "approval denied"
    })
  end

  defp emit_event(state, kind, payload) when is_binary(kind) and is_map(payload) do
    seq = state.seq + 1
    session_key = state.gateway_session_key || "fake_session"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    raw_event = %{
      "gateway_session_key" => session_key,
      "seq" => seq,
      "ts" => timestamp,
      "kind" => kind,
      "source" => "fake_client",
      "payload" => payload
    }

    event = %Event{
      gateway_session_key: session_key,
      seq: seq,
      ts: timestamp,
      kind: kind,
      source: "fake_client",
      payload: payload,
      raw: raw_event
    }

    send(state.owner, {:hivebeam_client, :event, event})
    %{state | seq: seq}
  end

  defp attach_session_key(arg, _state) when is_binary(arg), do: arg

  defp attach_session_key(arg, state) when is_list(arg) do
    Keyword.get(arg, :gateway_session_key, state.gateway_session_key)
  end

  defp attach_session_key(_arg, _state), do: nil

  defp normalize_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "claude" -> "claude"
      _ -> "codex"
    end
  rescue
    _ -> "codex"
  end

  defp normalize_decision(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "allow" -> "allow"
      "deny" -> "deny"
      _ -> "deny"
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
