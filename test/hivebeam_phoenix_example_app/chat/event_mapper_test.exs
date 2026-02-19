defmodule HivebeamPhoenixExampleApp.Chat.EventMapperTest do
  use ExUnit.Case, async: true

  alias HivebeamClient.Event
  alias HivebeamPhoenixExampleApp.Chat.EventMapper
  alias HivebeamPhoenixExampleApp.Chat.Thread

  test "extracts stream chunks and appends assistant text" do
    thread =
      Thread.new(%{"provider" => "codex"})
      |> Thread.add_user_message("req-1", "hello")
      |> Thread.ensure_assistant_message("req-1")

    event =
      event("stream_update", %{
        "request_id" => "req-1",
        "update" => %{"content" => %{"delta" => %{"text" => "chunk-1"}}}
      })

    updated = EventMapper.apply_event(thread, event)
    assistant = Enum.find(updated.messages, &(&1.role == :assistant))

    assert assistant.content == "chunk-1"
    assert updated.status == :running
    assert EventMapper.extract_stream_text(event.payload) == "chunk-1"
  end

  test "extracts stream text from list-based content updates" do
    payload = %{
      "request_id" => "req-1",
      "update" => %{
        "content" => [
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "```sh\n177.135.93.9\n```\n"}
          }
        ]
      }
    }

    assert EventMapper.extract_stream_text(payload) == "```sh\n177.135.93.9\n```\n"
  end

  test "maps approval requested and resolved events" do
    thread = Thread.new(%{"provider" => "codex"})

    requested =
      EventMapper.apply_event(
        thread,
        event("approval_requested", %{
          "approval_ref" => "apr_1",
          "request" => %{"tool_name" => "fake_tool"}
        })
      )

    assert Enum.any?(requested.approvals, &(&1.approval_ref == "apr_1" and &1.status == :pending))
    assert Enum.any?(requested.messages, &(&1.role == :approval and &1.approval_ref == "apr_1"))

    resolved =
      EventMapper.apply_event(
        requested,
        event("approval_resolved", %{
          "approval_ref" => "apr_1",
          "decision" => "allow"
        })
      )

    assert Enum.any?(resolved.approvals, &(&1.approval_ref == "apr_1" and &1.status == :allow))
  end

  test "handles unknown kinds and malformed payloads without crashing" do
    thread = Thread.new(%{"provider" => "codex"})

    malformed =
      EventMapper.apply_event(
        thread,
        event("stream_update", %{"update" => %{"text" => 123}})
      )

    assert malformed.messages == thread.messages
    assert malformed.event_counts["stream_update"] == 1

    unknown = EventMapper.apply_event(malformed, event("totally_unknown_kind", %{"foo" => "bar"}))
    assert unknown.event_counts["totally_unknown_kind"] == 1
    assert is_list(unknown.raw_events)
  end

  defp event(kind, payload) do
    raw = %{
      "gateway_session_key" => "gw_test",
      "seq" => 1,
      "ts" => "2026-01-01T00:00:00Z",
      "kind" => kind,
      "source" => "test",
      "payload" => payload
    }

    %Event{
      gateway_session_key: "gw_test",
      seq: 1,
      ts: "2026-01-01T00:00:00Z",
      kind: kind,
      source: "test",
      payload: payload,
      raw: raw
    }
  end
end
