defmodule HivebeamPhoenixExampleApp.Chat.SessionManagerTest do
  use ExUnit.Case, async: false

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers
  alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient

  setup do
    previous = System.get_env("HIVEBEAM_DEFAULT_APPROVAL_MODE")

    on_exit(fn ->
      if is_binary(previous) do
        System.put_env("HIVEBEAM_DEFAULT_APPROVAL_MODE", previous)
      else
        System.delete_env("HIVEBEAM_DEFAULT_APPROVAL_MODE")
      end
    end)

    :ok
  end

  test "create_thread uses env default approval mode when not provided" do
    System.put_env("HIVEBEAM_DEFAULT_APPROVAL_MODE", "allow")
    ChatTestHelpers.reset_runtime(FakeHivebeamClient)

    {:ok, thread} = SessionManager.create_thread(%{provider: "codex"})
    assert thread.approval_mode == "allow"
  end

  test "normal websocket close is not treated as thread error" do
    System.put_env("HIVEBEAM_DEFAULT_APPROVAL_MODE", "ask")
    ChatTestHelpers.reset_runtime(FakeHivebeamClient)

    {:ok, thread} = SessionManager.create_thread(%{provider: "codex"})
    assert is_nil(thread.last_error)

    send(
      SessionManager,
      {:thread_client_event, thread.id,
       {:hivebeam_client, :disconnected, %{reason: {:remote, 1000, ""}}}}
    )

    ChatTestHelpers.eventually(fn ->
      {:ok, updated} = SessionManager.get_thread(thread.id)
      assert updated.connected == false
      assert is_nil(updated.last_error)
    end)
  end
end
