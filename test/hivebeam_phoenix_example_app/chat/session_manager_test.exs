defmodule HivebeamPhoenixExampleApp.Chat.SessionManagerTest do
  use ExUnit.Case, async: false

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers
  alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient

  defmodule FallbackCwdFakeClient do
    alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient
    alias HivebeamClient.Error, as: HivebeamClientError

    def start_link(opts), do: FakeHivebeamClient.start_link(opts)
    def attach(server, arg), do: FakeHivebeamClient.attach(server, arg)

    def prompt(server, request_id, text, opts \\ []),
      do: FakeHivebeamClient.prompt(server, request_id, text, opts)

    def cancel(server, opts \\ []), do: FakeHivebeamClient.cancel(server, opts)

    def approve(server, approval_ref, decision, opts \\ []),
      do: FakeHivebeamClient.approve(server, approval_ref, decision, opts)

    def close(server, opts \\ []), do: FakeHivebeamClient.close(server, opts)

    def create_session(server, attrs \\ %{}) when is_map(attrs) do
      key = {__MODULE__, :fallback_failed_once, server}

      if Process.get(key) do
        FakeHivebeamClient.create_session(server, attrs)
      else
        Process.put(key, true)

        requested_cwd = attrs["cwd"] || attrs[:cwd] || "/tmp"

        {:error,
         %HivebeamClientError{
           type: :invalid_request,
           message: "cwd_outside_sandbox",
           status: 422,
           details: %{
             "error" => "cwd_outside_sandbox",
             "details" => %{
               "allowed_roots" => [File.cwd!()],
               "path" => requested_cwd
             }
           }
         }}
      end
    end
  end

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

  test "create_thread retries with gateway allowed root after cwd_outside_sandbox" do
    ChatTestHelpers.reset_runtime(FallbackCwdFakeClient)

    denied_cwd =
      Path.join(System.tmp_dir!(), "hivebeam_outside_#{System.unique_integer([:positive])}")

    {:ok, thread} = SessionManager.create_thread(%{provider: "codex", cwd: denied_cwd})

    assert thread.cwd == File.cwd!()
    assert is_binary(thread.gateway_session_key)
    assert thread.connected == true
    assert is_nil(thread.last_error)
  end
end
