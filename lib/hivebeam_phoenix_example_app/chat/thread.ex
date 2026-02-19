defmodule HivebeamPhoenixExampleApp.Chat.Thread do
  @moduledoc false

  alias HivebeamPhoenixExampleApp.GatewayConfig

  @type message_role :: :user | :assistant | :system | :approval

  @type message :: %{
          required(:id) => String.t(),
          required(:role) => message_role(),
          required(:content) => String.t(),
          required(:status) => atom(),
          required(:inserted_at) => String.t(),
          optional(:request_id) => String.t(),
          optional(:approval_ref) => String.t(),
          optional(:meta) => map()
        }

  @type approval :: %{
          required(:approval_ref) => String.t(),
          required(:status) => atom(),
          required(:inserted_at) => String.t(),
          optional(:decision) => String.t(),
          optional(:request) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          provider: String.t(),
          cwd: String.t(),
          approval_mode: String.t(),
          gateway_session_key: String.t() | nil,
          status: atom(),
          connected: boolean(),
          in_flight_request_id: String.t() | nil,
          last_error: String.t() | nil,
          messages: [message()],
          approvals: [approval()],
          event_counts: map(),
          raw_events: [map()],
          created_at: String.t(),
          updated_at: String.t()
        }

  @enforce_keys [:id, :title, :provider, :cwd, :approval_mode, :created_at, :updated_at]
  defstruct [
    :id,
    :title,
    :provider,
    :cwd,
    :approval_mode,
    :gateway_session_key,
    status: :starting,
    connected: false,
    in_flight_request_id: nil,
    last_error: nil,
    messages: [],
    approvals: [],
    event_counts: %{},
    raw_events: [],
    created_at: nil,
    updated_at: nil
  ]

  @raw_event_limit 200

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    now = now_iso()

    provider =
      GatewayConfig.normalize_provider(Map.get(attrs, :provider) || Map.get(attrs, "provider"))

    cwd =
      Map.get(attrs, :cwd) ||
        Map.get(attrs, "cwd") ||
        GatewayConfig.default_cwd()

    approval_mode =
      Map.get(attrs, :approval_mode) ||
        Map.get(attrs, "approval_mode") ||
        GatewayConfig.default_approval_mode()
        |> GatewayConfig.normalize_approval_mode()

    id =
      Map.get(attrs, :id) ||
        Map.get(attrs, "id") ||
        generate_id("thr")

    title =
      Map.get(attrs, :title) ||
        Map.get(attrs, "title") ||
        "#{String.capitalize(provider)} Thread"

    %__MODULE__{
      id: id,
      title: title,
      provider: provider,
      cwd: cwd,
      approval_mode: approval_mode,
      created_at: now,
      updated_at: now
    }
  end

  @spec put_gateway_session_key(t(), String.t()) :: t()
  def put_gateway_session_key(%__MODULE__{} = thread, key) when is_binary(key) do
    thread
    |> Map.put(:gateway_session_key, key)
    |> Map.put(:status, :idle)
    |> touch()
  end

  @spec put_connected(t(), boolean()) :: t()
  def put_connected(%__MODULE__{} = thread, connected?) when is_boolean(connected?) do
    thread
    |> Map.put(:connected, connected?)
    |> Map.put(:status, if(connected?, do: :idle, else: thread.status))
    |> touch()
  end

  @spec put_status(t(), atom()) :: t()
  def put_status(%__MODULE__{} = thread, status) when is_atom(status) do
    thread
    |> Map.put(:status, status)
    |> touch()
  end

  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = thread, reason) do
    thread
    |> Map.put(:status, :error)
    |> Map.put(:last_error, inspect(reason))
    |> touch()
  end

  @spec add_user_message(t(), String.t(), String.t()) :: t()
  def add_user_message(%__MODULE__{} = thread, request_id, text)
      when is_binary(request_id) and is_binary(text) do
    thread
    |> add_message(%{
      id: generate_id("msg"),
      role: :user,
      content: text,
      request_id: request_id,
      status: :complete,
      inserted_at: now_iso()
    })
    |> Map.put(:in_flight_request_id, request_id)
    |> Map.put(:status, :running)
    |> touch()
  end

  @spec ensure_assistant_message(t(), String.t()) :: t()
  def ensure_assistant_message(%__MODULE__{} = thread, request_id) when is_binary(request_id) do
    if Enum.any?(
         thread.messages,
         &(&1.role == :assistant and &1.request_id == request_id and &1.status == :streaming)
       ) do
      thread
    else
      add_message(thread, %{
        id: generate_id("msg"),
        role: :assistant,
        content: "",
        request_id: request_id,
        status: :streaming,
        inserted_at: now_iso()
      })
    end
  end

  @spec append_assistant_chunk(t(), String.t(), String.t()) :: t()
  def append_assistant_chunk(%__MODULE__{} = thread, request_id, chunk)
      when is_binary(request_id) and is_binary(chunk) do
    thread
    |> ensure_assistant_message(request_id)
    |> update_last_assistant_for_request(request_id, fn message ->
      message
      |> Map.update(:content, chunk, &(&1 <> chunk))
      |> Map.put(:status, :streaming)
    end)
    |> Map.put(:status, :running)
    |> touch()
  end

  @spec finish_assistant_message(t(), String.t() | nil, atom()) :: t()
  def finish_assistant_message(%__MODULE__{} = thread, request_id, status)
      when status in [:complete, :error, :cancelled] do
    request_id = request_id || thread.in_flight_request_id

    updated_thread =
      if is_binary(request_id) do
        update_last_assistant_for_request(thread, request_id, fn message ->
          Map.put(message, :status, status)
        end)
      else
        thread
      end

    updated_thread
    |> Map.put(:in_flight_request_id, nil)
    |> Map.put(:status, if(status == :error, do: :error, else: :idle))
    |> touch()
  end

  @spec add_approval(t(), String.t(), map()) :: t()
  def add_approval(%__MODULE__{} = thread, approval_ref, request_payload)
      when is_binary(approval_ref) and is_map(request_payload) do
    approval = %{
      approval_ref: approval_ref,
      status: :pending,
      request: request_payload,
      inserted_at: now_iso()
    }

    message = %{
      id: generate_id("msg"),
      role: :approval,
      content: "Approval required",
      approval_ref: approval_ref,
      status: :pending,
      meta: %{request: request_payload},
      inserted_at: now_iso()
    }

    thread
    |> Map.update(:approvals, [approval], &[approval | &1])
    |> add_message(message)
    |> touch()
  end

  @spec resolve_approval(t(), String.t(), String.t()) :: t()
  def resolve_approval(%__MODULE__{} = thread, approval_ref, decision)
      when is_binary(approval_ref) and is_binary(decision) do
    approval_status =
      case decision do
        "allow" -> :allow
        "deny" -> :deny
        _ -> :resolved
      end

    thread
    |> Map.update(:approvals, [], fn approvals ->
      Enum.map(approvals, fn approval ->
        if approval.approval_ref == approval_ref do
          approval
          |> Map.put(:status, approval_status)
          |> Map.put(:decision, decision)
        else
          approval
        end
      end)
    end)
    |> update_approval_message(approval_ref, approval_status)
    |> touch()
  end

  @spec timeout_approval(t(), String.t()) :: t()
  def timeout_approval(%__MODULE__{} = thread, approval_ref) when is_binary(approval_ref) do
    thread
    |> Map.update(:approvals, [], fn approvals ->
      Enum.map(approvals, fn approval ->
        if approval.approval_ref == approval_ref do
          Map.put(approval, :status, :timeout)
        else
          approval
        end
      end)
    end)
    |> update_approval_message(approval_ref, :timeout)
    |> touch()
  end

  @spec increment_event_count(t(), String.t()) :: t()
  def increment_event_count(%__MODULE__{} = thread, kind) when is_binary(kind) do
    update_in(thread.event_counts, &Map.update(&1, kind, 1, fn count -> count + 1 end))
  end

  @spec add_raw_event(t(), map()) :: t()
  def add_raw_event(%__MODULE__{} = thread, event) when is_map(event) do
    raw_events = [event | thread.raw_events] |> Enum.take(@raw_event_limit)
    %{thread | raw_events: raw_events}
  end

  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = thread) do
    %{thread | updated_at: now_iso()}
  end

  @spec generate_request_id() :: String.t()
  def generate_request_id do
    generate_id("req")
  end

  defp add_message(%__MODULE__{} = thread, message) when is_map(message) do
    %{thread | messages: thread.messages ++ [message]}
  end

  defp update_last_assistant_for_request(%__MODULE__{} = thread, request_id, fun) do
    reversed = Enum.reverse(thread.messages)

    {updated_reversed, changed?} =
      Enum.map_reduce(reversed, false, fn message, changed? ->
        cond do
          changed? ->
            {message, true}

          message.role == :assistant and message.request_id == request_id ->
            {fun.(message), true}

          true ->
            {message, false}
        end
      end)

    if changed? do
      %{thread | messages: Enum.reverse(updated_reversed)}
    else
      thread
    end
  end

  defp update_approval_message(%__MODULE__{} = thread, approval_ref, status) do
    messages =
      Enum.map(thread.messages, fn message ->
        if message.role == :approval and message.approval_ref == approval_ref do
          Map.put(message, :status, status)
        else
          message
        end
      end)

    %{thread | messages: messages}
  end

  defp generate_id(prefix) when is_binary(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{prefix}_#{suffix}"
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
