defmodule HivebeamPhoenixExampleAppWeb.ChatLiveTest do
  use HivebeamPhoenixExampleAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers
  alias HivebeamPhoenixExampleApp.TestSupport.FakeHivebeamClient

  setup do
    ChatTestHelpers.reset_runtime(FakeHivebeamClient)
    :ok
  end

  test "renders three panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/chat")

    assert html =~ "Session Inspector"
    assert html =~ "Thread History"
    assert html =~ "Start a conversation"
  end

  test "creates threads and switches active thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    codex = create_thread(view, "codex")
    claude = create_thread(view, "claude")
    assert codex.id != claude.id

    render_click(element(view, "button.hb-thread-item[phx-value-thread_id='#{codex.id}']"))
    assert_patch(view, ~p"/chat?thread_id=#{codex.id}")
    assert render(view) =~ "CODEX"
  end

  test "sends prompt and shows streamed assistant text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    _thread = create_thread(view, "codex")

    view
    |> form(".hb-composer", %{message: "hello from liveview"})
    |> render_submit()

    ChatTestHelpers.eventually(fn ->
      assert render(view) =~ "fake-client: hello from liveview"
      assert render(view) =~ "Agent"
    end)
  end

  test "renders approval cards and handles allow/deny", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    thread = create_thread(view, "codex")

    request_allow = send_approval_prompt(view, "approval required allow")

    assert has_element?(
             view,
             "button[phx-value-approval_ref='#{request_allow}'][phx-value-decision='allow']"
           )

    render_click(
      element(
        view,
        "button[phx-value-approval_ref='#{request_allow}'][phx-value-decision='allow']"
      )
    )

    ChatTestHelpers.eventually(fn ->
      {:ok, latest} = SessionManager.get_thread(thread.id)

      assert Enum.any?(
               latest.approvals,
               &(&1.approval_ref == request_allow and &1.status == :allow)
             )
    end)

    request_deny = send_approval_prompt(view, "approval required deny")

    assert has_element?(
             view,
             "button[phx-value-approval_ref='#{request_deny}'][phx-value-decision='deny']"
           )

    render_click(
      element(view, "button[phx-value-approval_ref='#{request_deny}'][phx-value-decision='deny']")
    )

    ChatTestHelpers.eventually(fn ->
      {:ok, latest} = SessionManager.get_thread(thread.id)

      assert Enum.any?(
               latest.approvals,
               &(&1.approval_ref == request_deny and &1.status == :deny)
             )
    end)
  end

  defp create_thread(view, provider) do
    view
    |> form(".hb-new-thread", %{provider: provider})
    |> render_submit()

    ChatTestHelpers.eventually(fn ->
      assert [%{} | _] = SessionManager.list_threads()
    end)

    thread =
      SessionManager.list_threads()
      |> Enum.find(fn entry -> entry.provider == provider end)

    assert thread
    assert_patch(view, ~p"/chat?thread_id=#{thread.id}")
    thread
  end

  defp send_approval_prompt(view, text) do
    view
    |> form(".hb-composer", %{message: text})
    |> render_submit()

    ChatTestHelpers.eventually(fn ->
      assert has_element?(view, "button[phx-click='approve_request'][phx-value-decision='allow']")
    end)

    latest =
      SessionManager.list_threads()
      |> hd()

    [approval | _rest] = Enum.filter(latest.approvals, &(&1.status == :pending))
    approval.approval_ref
  end
end
