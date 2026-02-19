defmodule HivebeamPhoenixExampleApp.Chat.SessionManager do
  @moduledoc false
  use GenServer

  alias HivebeamPhoenixExampleApp.Chat.ClientOwner
  alias HivebeamPhoenixExampleApp.Chat.ClientSupervisor
  alias HivebeamPhoenixExampleApp.Chat.EventMapper
  alias HivebeamPhoenixExampleApp.Chat.Thread
  alias HivebeamPhoenixExampleApp.Chat.ThreadStore
  alias HivebeamPhoenixExampleApp.GatewayConfig

  @registry HivebeamPhoenixExampleApp.Chat.ClientRegistry
  @pubsub HivebeamPhoenixExampleApp.PubSub
  @gateway_call_timeout_ms 30_000

  @type thread_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec threads_topic() :: String.t()
  def threads_topic, do: "chat:threads"

  @spec thread_topic(String.t()) :: String.t()
  def thread_topic(thread_id) when is_binary(thread_id), do: "chat:thread:" <> thread_id

  @spec create_thread(map() | keyword()) :: {:ok, Thread.t()} | {:error, term()}
  def create_thread(attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_thread, attrs}, @gateway_call_timeout_ms)
  end

  @spec list_threads() :: [Thread.t()]
  def list_threads do
    GenServer.call(__MODULE__, :list_threads)
  end

  @spec get_thread(thread_id()) :: {:ok, Thread.t()} | {:error, :not_found}
  def get_thread(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:get_thread, thread_id})
  end

  @spec send_prompt(thread_id(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def send_prompt(thread_id, text, opts \\ %{}) when is_binary(thread_id) and is_binary(text) do
    GenServer.call(__MODULE__, {:send_prompt, thread_id, text, opts}, @gateway_call_timeout_ms)
  end

  @spec cancel_prompt(thread_id()) :: {:ok, map()} | {:error, term()}
  def cancel_prompt(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:cancel_prompt, thread_id}, @gateway_call_timeout_ms)
  end

  @spec approve_request(thread_id(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def approve_request(thread_id, approval_ref, decision)
      when is_binary(thread_id) and is_binary(approval_ref) and is_binary(decision) do
    GenServer.call(
      __MODULE__,
      {:approve_request, thread_id, approval_ref, decision},
      @gateway_call_timeout_ms
    )
  end

  @spec close_thread(thread_id()) :: {:ok, map()} | {:error, term()}
  def close_thread(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:close_thread, thread_id}, @gateway_call_timeout_ms)
  end

  @impl true
  def init(opts) do
    client_module =
      Keyword.get(opts, :client_module) ||
        Application.get_env(
          :hivebeam_phoenix_example_app,
          :hivebeam_client_module,
          HivebeamClient
        )

    {:ok,
     %{
       client_module: client_module,
       runtimes: %{},
       monitor_index: %{}
     }}
  end

  @impl true
  def handle_call(:list_threads, _from, state) do
    {:reply, ThreadStore.list_threads(), state}
  end

  def handle_call({:get_thread, thread_id}, _from, state) do
    {:reply, ThreadStore.get_thread(thread_id), state}
  end

  def handle_call({:create_thread, attrs}, _from, state) do
    attrs = normalize_thread_attrs(attrs)

    with {:ok, thread} <- ThreadStore.create_thread(attrs),
         {:ok, thread, state} <- activate_thread(thread, state) do
      broadcast_thread(thread)
      broadcast_threads()
      {:reply, {:ok, thread}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_prompt, thread_id, text, opts}, _from, state) do
    with {:ok, thread} <- ThreadStore.get_thread(thread_id),
         {:ok, _active_thread, state} <- ensure_thread_active(thread, state) do
      request_id = extract_request_id(opts) || Thread.generate_request_id()
      timeout_ms = extract_timeout(opts)

      {:ok, updated_thread} =
        ThreadStore.update_thread(thread_id, fn current ->
          current
          |> Thread.add_user_message(request_id, text)
          |> Thread.ensure_assistant_message(request_id)
        end)

      client_name = client_name(thread_id)
      prompt_opts = if is_integer(timeout_ms), do: [timeout_ms: timeout_ms], else: []

      case state.client_module.prompt(client_name, request_id, text, prompt_opts) do
        {:ok, payload} ->
          broadcast_thread(updated_thread)
          broadcast_threads()
          {:reply, {:ok, payload}, state}

        {:error, reason} ->
          {:ok, errored_thread} =
            ThreadStore.update_thread(thread_id, fn current ->
              current
              |> Thread.finish_assistant_message(request_id, :error)
              |> Thread.put_error(reason)
            end)

          broadcast_thread(errored_thread)
          broadcast_threads()
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_prompt, thread_id}, _from, state) do
    with {:ok, thread} <- ThreadStore.get_thread(thread_id),
         {:ok, _thread, state} <- ensure_thread_active(thread, state) do
      case state.client_module.cancel(client_name(thread_id)) do
        {:ok, payload} -> {:reply, {:ok, payload}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve_request, thread_id, approval_ref, decision}, _from, state) do
    with {:ok, thread} <- ThreadStore.get_thread(thread_id),
         {:ok, _thread, state} <- ensure_thread_active(thread, state) do
      case state.client_module.approve(client_name(thread_id), approval_ref, decision, []) do
        {:ok, payload} ->
          {:ok, updated_thread} =
            ThreadStore.update_thread(thread_id, fn current ->
              Thread.resolve_approval(current, approval_ref, decision)
            end)

          broadcast_thread(updated_thread)
          broadcast_threads()
          {:reply, {:ok, payload}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_thread, thread_id}, _from, state) do
    with {:ok, thread} <- ThreadStore.get_thread(thread_id) do
      _ = maybe_close_gateway_session(state, thread)

      next_state = teardown_runtime(thread_id, state)
      :ok = ThreadStore.delete_thread(thread_id)

      broadcast_threads()
      Phoenix.PubSub.broadcast(@pubsub, thread_topic(thread_id), {:thread_closed, thread_id})

      {:reply, {:ok, %{closed: true, thread_id: thread_id}}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:thread_client_event, thread_id, {:hivebeam_client, :event, event}}, state)
      when is_binary(thread_id) do
    maybe_broadcast_thread(
      ThreadStore.update_thread(thread_id, fn thread -> EventMapper.apply_event(thread, event) end)
    )

    {:noreply, state}
  end

  def handle_info({:thread_client_event, thread_id, {:hivebeam_client, :connected, _meta}}, state)
      when is_binary(thread_id) do
    maybe_broadcast_thread(
      ThreadStore.update_thread(thread_id, fn thread ->
        thread
        |> Thread.put_connected(true)
        |> Thread.put_status(:idle)
      end)
    )

    {:noreply, state}
  end

  def handle_info(
        {:thread_client_event, thread_id, {:hivebeam_client, :disconnected, reason}},
        state
      )
      when is_binary(thread_id) do
    maybe_broadcast_thread(
      ThreadStore.update_thread(thread_id, fn thread ->
        thread
        |> Thread.put_connected(false)
        |> Thread.put_error(reason)
      end)
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitor_index, ref) do
      {nil, _index} ->
        {:noreply, state}

      {{thread_id, kind}, monitor_index} ->
        next_state =
          state
          |> Map.put(:monitor_index, monitor_index)
          |> drop_runtime_pid(thread_id, kind)

        maybe_broadcast_thread(
          ThreadStore.update_thread(thread_id, fn thread ->
            thread
            |> Thread.put_connected(false)
            |> Thread.put_error({kind, reason})
          end)
        )

        {:noreply, next_state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp activate_thread(thread, state) do
    with {:ok, thread, state} <- ensure_thread_active(thread, state),
         {:ok, reloaded} <- ThreadStore.get_thread(thread.id) do
      {:ok, reloaded, state}
    end
  end

  defp ensure_thread_active(%Thread{} = thread, state) do
    with {:ok, state} <- ensure_client(thread, state) do
      if is_binary(thread.gateway_session_key) and thread.gateway_session_key != "" do
        {:ok, thread, state}
      else
        create_and_attach_session(thread, state)
      end
    end
  end

  defp ensure_client(%Thread{} = thread, state) do
    thread_id = thread.id

    case Map.get(state.runtimes, thread_id) do
      %{client_pid: client_pid} ->
        if is_pid(client_pid) and Process.alive?(client_pid) do
          {:ok, state}
        else
          start_client_runtime(thread, state)
        end

      _runtime ->
        start_client_runtime(thread, state)
    end
  end

  defp start_client_runtime(%Thread{} = thread, state) do
    owner_spec = %{
      id: {:thread_owner, thread.id},
      start: {ClientOwner, :start_link, [[thread_id: thread.id, manager: self()]]},
      restart: :temporary,
      type: :worker
    }

    with {:ok, owner_pid} <- DynamicSupervisor.start_child(ClientSupervisor, owner_spec),
         {:ok, client_pid} <- start_client(thread, owner_pid, state.client_module) do
      owner_ref = Process.monitor(owner_pid)
      client_ref = Process.monitor(client_pid)

      runtime = %{
        owner_pid: owner_pid,
        client_pid: client_pid,
        owner_ref: owner_ref,
        client_ref: client_ref
      }

      monitor_index =
        state.monitor_index
        |> Map.put(owner_ref, {thread.id, :owner})
        |> Map.put(client_ref, {thread.id, :client})

      {:ok,
       state
       |> put_in([:runtimes, thread.id], runtime)
       |> Map.put(:monitor_index, monitor_index)}
    else
      {:error, {:already_started, _pid}} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_client(%Thread{} = thread, owner_pid, client_module) do
    client_spec = %{
      id: {:thread_client, thread.id},
      start: {client_module, :start_link, [client_start_opts(thread, owner_pid)]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(ClientSupervisor, client_spec)
  end

  defp create_and_attach_session(thread, state) do
    session_attrs =
      GatewayConfig.create_session_attrs(thread.provider, thread.cwd, thread.approval_mode)

    with {:ok, session} <-
           state.client_module.create_session(client_name(thread.id), session_attrs),
         session_key when is_binary(session_key) and session_key != "" <-
           session["gateway_session_key"],
         {:ok, _attach_payload} <- state.client_module.attach(client_name(thread.id), session_key),
         {:ok, updated_thread} <-
           ThreadStore.update_thread(thread.id, fn current ->
             current
             |> Thread.put_gateway_session_key(session_key)
             |> Thread.put_connected(true)
             |> Thread.put_status(:idle)
           end) do
      broadcast_thread(updated_thread)
      broadcast_threads()
      {:ok, updated_thread, state}
    else
      {:error, reason} ->
        maybe_broadcast_thread(
          ThreadStore.update_thread(thread.id, fn current -> Thread.put_error(current, reason) end)
        )

        {:error, reason, state}

      _ ->
        reason = :invalid_gateway_session_key

        maybe_broadcast_thread(
          ThreadStore.update_thread(thread.id, fn current -> Thread.put_error(current, reason) end)
        )

        {:error, reason, state}
    end
  end

  defp teardown_runtime(thread_id, state) do
    case Map.pop(state.runtimes, thread_id) do
      {nil, runtimes} ->
        %{state | runtimes: runtimes}

      {runtime, runtimes} ->
        maybe_stop_child(runtime.client_pid)
        maybe_stop_child(runtime.owner_pid)

        monitor_index =
          state.monitor_index
          |> Map.delete(runtime.client_ref)
          |> Map.delete(runtime.owner_ref)

        %{state | runtimes: runtimes, monitor_index: monitor_index}
    end
  end

  defp drop_runtime_pid(state, thread_id, kind) do
    update_in(state.runtimes, fn runtimes ->
      case Map.get(runtimes, thread_id) do
        nil ->
          runtimes

        runtime ->
          runtime =
            case kind do
              :client -> Map.put(runtime, :client_pid, nil)
              :owner -> Map.put(runtime, :owner_pid, nil)
            end

          Map.put(runtimes, thread_id, runtime)
      end
    end)
  end

  defp maybe_close_gateway_session(state, thread) do
    if is_binary(thread.gateway_session_key) and thread.gateway_session_key != "" do
      state.client_module.close(client_name(thread.id), [])
    else
      {:ok, %{closed: true}}
    end
  rescue
    _ ->
      {:error, :close_failed}
  end

  defp client_start_opts(thread, owner_pid) do
    GatewayConfig.client_opts(thread.provider, thread.cwd, thread.approval_mode)
    |> Keyword.put(:name, client_name(thread.id))
    |> Keyword.put(:owner, owner_pid)
  end

  defp client_name(thread_id) do
    {:via, Registry, {@registry, {:thread_client, thread_id}}}
  end

  defp normalize_thread_attrs(attrs) when is_list(attrs),
    do: attrs |> Map.new() |> normalize_thread_attrs()

  defp normalize_thread_attrs(attrs) when is_map(attrs) do
    provider = GatewayConfig.normalize_provider(attrs[:provider] || attrs["provider"])
    cwd = attrs[:cwd] || attrs["cwd"] || GatewayConfig.default_cwd()

    approval_mode =
      GatewayConfig.normalize_approval_mode(attrs[:approval_mode] || attrs["approval_mode"])

    title = attrs[:title] || attrs["title"] || "#{String.capitalize(provider)} Thread"

    %{
      provider: provider,
      cwd: cwd,
      approval_mode: approval_mode,
      title: title
    }
  end

  defp normalize_thread_attrs(_attrs), do: normalize_thread_attrs(%{})

  defp extract_request_id(opts) when is_list(opts), do: Keyword.get(opts, :request_id)

  defp extract_request_id(opts) when is_map(opts) do
    opts[:request_id] || opts["request_id"]
  end

  defp extract_request_id(_opts), do: nil

  defp extract_timeout(opts) when is_list(opts) do
    case Keyword.get(opts, :timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp extract_timeout(opts) when is_map(opts) do
    case opts[:timeout_ms] || opts["timeout_ms"] do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp extract_timeout(_opts), do: nil

  defp maybe_broadcast_thread({:ok, thread}) do
    broadcast_thread(thread)
    broadcast_threads()
  end

  defp maybe_broadcast_thread(_other), do: :ok

  defp broadcast_thread(%Thread{} = thread) do
    Phoenix.PubSub.broadcast(@pubsub, thread_topic(thread.id), {:thread_updated, thread})
  end

  defp broadcast_threads do
    Phoenix.PubSub.broadcast(@pubsub, threads_topic(), {:threads_updated})
  end

  defp maybe_stop_child(nil), do: :ok

  defp maybe_stop_child(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(ClientSupervisor, pid)
    else
      :ok
    end
  rescue
    _ ->
      :ok
  end
end
