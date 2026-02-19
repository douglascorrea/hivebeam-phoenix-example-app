defmodule HivebeamPhoenixExampleApp.Chat.EventMapper do
  @moduledoc false

  alias HivebeamClient.Event
  alias HivebeamPhoenixExampleApp.Chat.Thread

  @spec apply_event(Thread.t(), Event.t()) :: Thread.t()
  def apply_event(%Thread{} = thread, %Event{} = event) do
    payload = normalize_payload(event.payload)

    thread =
      thread
      |> Thread.increment_event_count(event.kind)
      |> Thread.add_raw_event(event.raw)

    case event.kind do
      "prompt_enqueued" ->
        Thread.put_status(thread, :running)

      "prompt_started" ->
        request_id = payload["request_id"] || payload["requestId"] || thread.in_flight_request_id

        thread
        |> maybe_set_request_id(request_id)
        |> Thread.put_status(:running)

      "stream_update" ->
        apply_stream_update(thread, payload)

      "stream_done" ->
        request_id = request_id_for(thread, payload)
        Thread.finish_assistant_message(thread, request_id, :complete)

      "stream_error" ->
        request_id = request_id_for(thread, payload)
        Thread.finish_assistant_message(thread, request_id, :error)

      "prompt_completed" ->
        request_id = request_id_for(thread, payload)
        Thread.finish_assistant_message(thread, request_id, :complete)

      "prompt_failed" ->
        request_id = request_id_for(thread, payload)

        thread
        |> Thread.finish_assistant_message(request_id, :error)
        |> Thread.put_error(payload["reason"] || "prompt_failed")

      "cancel_requested" ->
        request_id = request_id_for(thread, payload)
        Thread.finish_assistant_message(thread, request_id, :cancelled)

      "approval_requested" ->
        approval_ref = payload["approval_ref"]
        request_payload = normalize_map(payload["request"])

        if is_binary(approval_ref) and approval_ref != "" do
          Thread.add_approval(thread, approval_ref, request_payload)
        else
          thread
        end

      "approval_resolved" ->
        approval_ref = payload["approval_ref"]
        decision = payload["decision"] || "resolved"

        if is_binary(approval_ref) and approval_ref != "" do
          Thread.resolve_approval(thread, approval_ref, decision)
        else
          thread
        end

      "approval_timeout" ->
        approval_ref = payload["approval_ref"]

        if is_binary(approval_ref) and approval_ref != "" do
          Thread.timeout_approval(thread, approval_ref)
        else
          thread
        end

      "upstream_connected" ->
        Thread.put_connected(thread, true)

      "upstream_disconnected" ->
        Thread.put_connected(thread, false)

      "session_closed" ->
        Thread.put_status(thread, :closed)

      _other ->
        thread
    end
  end

  @spec extract_stream_text(map()) :: String.t()
  def extract_stream_text(payload) when is_map(payload) do
    payload = normalize_payload(payload)
    update = normalize_map(payload["update"])

    direct =
      update["text"] ||
        get_in(update, ["content", "text"]) ||
        get_in(update, ["delta", "text"]) ||
        get_in(update, ["content", "delta", "text"]) ||
        payload["text"]

    case direct do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  @spec extract_request_id(map()) :: String.t() | nil
  def extract_request_id(payload) when is_map(payload) do
    payload = normalize_payload(payload)

    payload["request_id"] ||
      payload["requestId"] ||
      get_in(payload, ["update", "request_id"]) ||
      get_in(payload, ["update", "requestId"])
  end

  def extract_request_id(_payload), do: nil

  defp apply_stream_update(%Thread{} = thread, payload) do
    request_id = request_id_for(thread, payload)
    chunk = extract_stream_text(payload)

    cond do
      not is_binary(request_id) ->
        thread

      chunk == "" ->
        thread

      true ->
        Thread.append_assistant_chunk(thread, request_id, chunk)
    end
  end

  defp request_id_for(thread, payload) do
    extract_request_id(payload) || thread.in_flight_request_id
  end

  defp maybe_set_request_id(thread, value) when is_binary(value) and value != "" do
    %{thread | in_flight_request_id: value}
  end

  defp maybe_set_request_id(thread, _value), do: thread

  defp normalize_payload(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      key = normalize_key(key)

      normalized_value =
        cond do
          is_map(value) -> normalize_payload(value)
          is_list(value) -> Enum.map(value, &normalize_value/1)
          true -> value
        end

      Map.put(acc, key, normalized_value)
    end)
  end

  defp normalize_payload(_payload), do: %{}

  defp normalize_map(value) when is_map(value), do: normalize_payload(value)
  defp normalize_map(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_payload(value)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)
end
