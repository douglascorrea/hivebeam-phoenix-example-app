defmodule HivebeamPhoenixExampleApp.Chat.ThreadStoreTest do
  use ExUnit.Case, async: false

  alias HivebeamPhoenixExampleApp.Chat.Thread
  alias HivebeamPhoenixExampleApp.Chat.ThreadStore
  alias HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers
  alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient

  setup do
    ChatTestHelpers.reset_runtime(FakeHivebeamClient)
    :ok
  end

  test "create/list/get returns threads with newest first" do
    {:ok, first} = ThreadStore.create_thread(%{provider: "codex", title: "First"})
    Process.sleep(2)
    {:ok, second} = ThreadStore.create_thread(%{provider: "claude", title: "Second"})

    threads = ThreadStore.list_threads()

    assert length(threads) == 2
    assert hd(threads).id == second.id
    assert Enum.at(threads, 1).id == first.id
    assert {:ok, fetched} = ThreadStore.get_thread(first.id)
    assert fetched.title == "First"
  end

  test "update allows message append and stream merge" do
    {:ok, thread} = ThreadStore.create_thread(%{provider: "codex"})

    {:ok, updated} =
      ThreadStore.update_thread(thread.id, fn current ->
        current
        |> Thread.add_user_message("req-1", "hello")
        |> Thread.ensure_assistant_message("req-1")
        |> Thread.append_assistant_chunk("req-1", "part-1")
        |> Thread.append_assistant_chunk("req-1", " part-2")
        |> Thread.finish_assistant_message("req-1", :complete)
      end)

    assistant = Enum.find(updated.messages, &(&1.role == :assistant and &1.request_id == "req-1"))
    assert assistant.content == "part-1 part-2"
    assert assistant.status == :complete
  end

  test "clear resets runtime-backed state" do
    {:ok, thread} = ThreadStore.create_thread(%{provider: "codex"})
    assert {:ok, _thread} = ThreadStore.get_thread(thread.id)

    assert :ok = ThreadStore.clear()
    assert ThreadStore.list_threads() == []
    assert {:error, :not_found} = ThreadStore.get_thread(thread.id)
  end
end
