defmodule HivebeamPhoenixExampleAppWeb.ChatLive do
  @moduledoc false
  use HivebeamPhoenixExampleAppWeb, :live_view

  import HivebeamPhoenixExampleAppWeb.ChatComponents

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.Chat.ThreadStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HivebeamPhoenixExampleApp.PubSub, SessionManager.threads_topic())
    end

    threads = SessionManager.list_threads()

    {:ok,
     socket
     |> assign(:threads, threads)
     |> assign(:active_thread_id, nil)
     |> assign(:active_thread, nil)
     |> assign(:subscribed_thread_id, nil)
     |> assign(:message_text, "")
     |> assign(:show_left_panel, false)
     |> assign(:show_right_panel, false)
     |> assign(:page_title, "Hivebeam Gateway Chat")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    threads = SessionManager.list_threads()
    requested_id = params["thread_id"]

    target_thread_id =
      cond do
        is_binary(requested_id) and requested_id != "" -> requested_id
        is_binary(socket.assigns.active_thread_id) -> socket.assigns.active_thread_id
        true -> first_thread_id(threads)
      end

    socket =
      socket
      |> assign(:threads, threads)
      |> attach_thread_subscription(target_thread_id)
      |> assign(:active_thread_id, target_thread_id)
      |> assign(:active_thread, resolve_thread(target_thread_id))

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_thread", %{"provider" => provider}, socket) do
    case SessionManager.create_thread(%{"provider" => provider}) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{String.upcase(thread.provider)} thread")
         |> push_patch(to: ~p"/chat?thread_id=#{thread.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create thread: #{inspect(reason)}")}
    end
  end

  def handle_event("select_thread", %{"thread_id" => thread_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat?thread_id=#{thread_id}")}
  end

  def handle_event("update_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, :message_text, message)}
  end

  def handle_event("send_prompt", %{"message" => message}, socket) do
    thread_id = socket.assigns.active_thread_id
    text = String.trim(message)

    cond do
      not is_binary(thread_id) ->
        {:noreply, put_flash(socket, :error, "Create a thread first")}

      text == "" ->
        {:noreply, socket}

      true ->
        case SessionManager.send_prompt(thread_id, text, %{}) do
          {:ok, _payload} ->
            {:noreply, assign(socket, :message_text, "")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Prompt failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("cancel_prompt", %{"thread_id" => thread_id}, socket) do
    case SessionManager.cancel_prompt(thread_id) do
      {:ok, _payload} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cancel failed: #{inspect(reason)}")}
    end
  end

  def handle_event("close_thread", %{"thread_id" => thread_id}, socket) do
    case SessionManager.close_thread(thread_id) do
      {:ok, _payload} ->
        target_id =
          SessionManager.list_threads()
          |> first_thread_id()

        if is_binary(target_id) do
          {:noreply, push_patch(socket, to: ~p"/chat?thread_id=#{target_id}")}
        else
          {:noreply, push_patch(socket, to: ~p"/chat")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Close failed: #{inspect(reason)}")}
    end
  end

  def handle_event("approve_request", params, socket) do
    thread_id = params["thread_id"]
    approval_ref = params["approval_ref"]
    decision = params["decision"]

    case SessionManager.approve_request(thread_id, approval_ref, decision) do
      {:ok, _payload} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approval failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_left_panel", _params, socket) do
    {:noreply, assign(socket, :show_left_panel, !socket.assigns.show_left_panel)}
  end

  def handle_event("toggle_right_panel", _params, socket) do
    {:noreply, assign(socket, :show_right_panel, !socket.assigns.show_right_panel)}
  end

  @impl true
  def handle_info({:threads_updated}, socket) do
    {:noreply, refresh_socket(socket)}
  end

  def handle_info({:thread_updated, _thread}, socket) do
    {:noreply, refresh_socket(socket)}
  end

  def handle_info({:thread_closed, thread_id}, socket) do
    if socket.assigns.active_thread_id == thread_id do
      next_id = first_thread_id(SessionManager.list_threads())

      if is_binary(next_id) do
        {:noreply, push_patch(socket, to: ~p"/chat?thread_id=#{next_id}")}
      else
        {:noreply, push_patch(socket, to: ~p"/chat")}
      end
    else
      {:noreply, refresh_socket(socket)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="hb-app-shell">
      <.top_bar
        active_thread={@active_thread}
        show_left_panel={@show_left_panel}
        show_right_panel={@show_right_panel}
      />

      <div class="hb-main-grid">
        <div class={left_panel_class(@show_left_panel)}>
          <.left_panel active_thread={@active_thread} />
        </div>

        <.center_panel active_thread={@active_thread} message_text={@message_text} />

        <div class={right_panel_class(@show_right_panel)}>
          <.right_panel threads={@threads} active_thread_id={@active_thread_id} />
        </div>
      </div>
    </div>
    """
  end

  defp refresh_socket(socket) do
    threads = SessionManager.list_threads()
    active_thread_id = normalize_active_thread_id(socket.assigns.active_thread_id, threads)

    socket
    |> assign(:threads, threads)
    |> assign(:active_thread_id, active_thread_id)
    |> assign(:active_thread, resolve_thread(active_thread_id))
    |> attach_thread_subscription(active_thread_id)
  end

  defp resolve_thread(nil), do: nil

  defp resolve_thread(thread_id) do
    case ThreadStore.get_thread(thread_id) do
      {:ok, thread} -> thread
      {:error, :not_found} -> nil
    end
  end

  defp normalize_active_thread_id(nil, threads), do: first_thread_id(threads)

  defp normalize_active_thread_id(thread_id, threads) when is_binary(thread_id) do
    if Enum.any?(threads, &(&1.id == thread_id)) do
      thread_id
    else
      first_thread_id(threads)
    end
  end

  defp normalize_active_thread_id(_thread_id, threads), do: first_thread_id(threads)

  defp first_thread_id([thread | _rest]), do: thread.id
  defp first_thread_id([]), do: nil

  defp attach_thread_subscription(socket, target_thread_id) do
    current_id = socket.assigns.subscribed_thread_id

    cond do
      not connected?(socket) ->
        socket

      current_id == target_thread_id ->
        socket

      true ->
        if is_binary(current_id) do
          Phoenix.PubSub.unsubscribe(
            HivebeamPhoenixExampleApp.PubSub,
            SessionManager.thread_topic(current_id)
          )
        end

        if is_binary(target_thread_id) do
          Phoenix.PubSub.subscribe(
            HivebeamPhoenixExampleApp.PubSub,
            SessionManager.thread_topic(target_thread_id)
          )
        end

        assign(socket, :subscribed_thread_id, target_thread_id)
    end
  end

  defp left_panel_class(show_left?) do
    if show_left? do
      "hb-side-slot hb-side-left is-open"
    else
      "hb-side-slot hb-side-left"
    end
  end

  defp right_panel_class(show_right?) do
    if show_right? do
      "hb-side-slot hb-side-right is-open"
    else
      "hb-side-slot hb-side-right"
    end
  end
end
