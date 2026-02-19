defmodule HivebeamPhoenixExampleApp.Integration.ChatGatewayIntegrationTest do
  use ExUnit.Case, async: false

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.Chat.ThreadStore
  alias HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers
  alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient
  alias HivebeamPhoenixExampleApp.TestSupport.GatewayHarness

  @moduletag :integration

  @env_keys [
    "HIVEBEAM_GATEWAY_BASE_URL",
    "HIVEBEAM_GATEWAY_TOKEN",
    "HIVEBEAM_DEFAULT_PROVIDER",
    "HIVEBEAM_DEFAULT_CWD",
    "HIVEBEAM_DEFAULT_APPROVAL_MODE",
    "HIVEBEAM_CLIENT_REQUEST_TIMEOUT_MS",
    "HIVEBEAM_CLIENT_WS_RECONNECT_MS",
    "HIVEBEAM_CLIENT_POLL_INTERVAL_MS"
  ]

  setup_all do
    {:ok, harness} = GatewayHarness.start_link()
    gateway = GatewayHarness.info(harness)

    on_exit(fn ->
      Process.exit(harness, :normal)
    end)

    {:ok, gateway: gateway}
  end

  setup %{gateway: gateway} do
    previous_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)

    System.put_env("HIVEBEAM_GATEWAY_BASE_URL", gateway.base_url)
    System.put_env("HIVEBEAM_GATEWAY_TOKEN", gateway.token)
    System.put_env("HIVEBEAM_DEFAULT_CWD", File.cwd!())
    System.put_env("HIVEBEAM_DEFAULT_PROVIDER", "codex")
    System.put_env("HIVEBEAM_DEFAULT_APPROVAL_MODE", "ask")
    System.put_env("HIVEBEAM_CLIENT_REQUEST_TIMEOUT_MS", "30000")
    System.put_env("HIVEBEAM_CLIENT_WS_RECONNECT_MS", "600")
    System.put_env("HIVEBEAM_CLIENT_POLL_INTERVAL_MS", "120")

    ChatTestHelpers.reset_runtime(HivebeamClient)

    on_exit(fn ->
      restore_env(previous_env)
      ChatTestHelpers.reset_runtime(FakeHivebeamClient)
    end)

    :ok
  end

  test "creates codex and claude threads and streams prompt completions" do
    {:ok, codex} = SessionManager.create_thread(%{provider: "codex", title: "Codex Integration"})

    {:ok, claude} =
      SessionManager.create_thread(%{provider: "claude", title: "Claude Integration"})

    assert codex.provider == "codex"
    assert claude.provider == "claude"
    assert is_binary(codex.gateway_session_key)
    assert is_binary(claude.gateway_session_key)

    assert {:ok, _payload} = SessionManager.send_prompt(codex.id, "hello codex integration", %{})

    assert {:ok, _payload} =
             SessionManager.send_prompt(claude.id, "hello claude integration", %{})

    assert_prompt_completed(codex.id, "fake-acp: prompt complete")
    assert_prompt_completed(claude.id, "fake-acp: prompt complete")
  end

  test "approval request and resolution flow succeeds" do
    {:ok, thread} = SessionManager.create_thread(%{provider: "codex"})
    assert {:ok, _payload} = SessionManager.send_prompt(thread.id, "needs approval now", %{})

    approval_ref = approve_pending(thread.id, "allow")

    wait_for_thread(thread.id, fn current ->
      assert Enum.any?(
               current.approvals,
               &(&1.approval_ref == approval_ref and &1.status == :allow)
             )

      assert current.event_counts["approval_resolved"] >= 1
    end)
  end

  test "cancel path is reachable" do
    {:ok, thread} = SessionManager.create_thread(%{provider: "codex"})
    assert {:ok, _payload} = SessionManager.send_prompt(thread.id, "cancel me", %{})
    assert {:ok, payload} = SessionManager.cancel_prompt(thread.id)
    assert is_boolean(payload["accepted"])

    wait_for_thread(thread.id, fn current ->
      assert current.event_counts["cancel_requested"] >= 1
    end)
  end

  test "ws reconnect does not break thread runtime state" do
    {:ok, thread} = SessionManager.create_thread(%{provider: "codex"})
    assert {:ok, _payload} = SessionManager.send_prompt(thread.id, "first prompt", %{})
    assert_prompt_completed(thread.id, "fake-acp: prompt complete")

    {:ok, client_pid} = ChatTestHelpers.runtime_client_pid(thread.id)
    client_state = :sys.get_state(client_pid)
    assert is_pid(client_state.ws_pid)
    Process.exit(client_state.ws_pid, :kill)

    wait_for_thread(thread.id, fn current ->
      assert current.connected == false
    end)

    assert {:ok, _payload} =
             SessionManager.send_prompt(thread.id, "second prompt after ws reset", %{})

    assert_prompt_completed(thread.id, "fake-acp: prompt complete")

    wait_for_thread(thread.id, fn current ->
      assert current.connected == true
    end)
  end

  defp assert_prompt_completed(thread_id, expected_text) do
    wait_for_thread(thread_id, fn thread ->
      assistant =
        thread.messages
        |> Enum.reverse()
        |> Enum.find(fn message ->
          message.role == :assistant and
            message.status == :complete and
            String.contains?(message.content, expected_text)
        end)

      assert assistant
    end)
  end

  defp wait_for_thread(thread_id, assertion_fun)
       when is_binary(thread_id) and is_function(assertion_fun, 1) do
    ChatTestHelpers.eventually(
      fn ->
        case ThreadStore.get_thread(thread_id) do
          {:ok, thread} -> assertion_fun.(thread)
          {:error, :not_found} -> flunk("thread not found: #{thread_id}")
        end
      end,
      240,
      50
    )
  end

  defp approve_pending(thread_id, decision) when decision in ["allow", "deny"] do
    wait_for_thread(thread_id, fn current ->
      approvals = Enum.filter(current.approvals, &(&1.status == :pending))
      assert approvals != []
      approval_ref = hd(approvals).approval_ref

      case SessionManager.approve_request(thread_id, approval_ref, decision) do
        {:ok, _payload} -> approval_ref
        {:error, %HivebeamClient.Error{type: :not_found}} -> flunk("approval not ready")
        {:error, reason} -> flunk("approval failed: #{inspect(reason)}")
      end
    end)
  end

  defp restore_env(previous_env) when is_map(previous_env) do
    Enum.each(previous_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
