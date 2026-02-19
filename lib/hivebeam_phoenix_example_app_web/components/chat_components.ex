defmodule HivebeamPhoenixExampleAppWeb.ChatComponents do
  @moduledoc false
  use Phoenix.Component

  import HivebeamPhoenixExampleAppWeb.CoreComponents

  alias HivebeamPhoenixExampleApp.Chat.Thread

  attr :active_thread, :any, default: nil
  attr :show_left_panel, :boolean, default: false
  attr :show_right_panel, :boolean, default: false

  def top_bar(assigns) do
    ~H"""
    <header class="hb-topbar">
      <button
        type="button"
        class="hb-icon-btn mobile-only"
        phx-click="toggle_left_panel"
        title="Session panel"
      >
        <.icon name="hero-squares-2x2" class="h-5 w-5" />
      </button>

      <div class="hb-title-wrap">
        <h1 class="hb-title">Hivebeam Gateway Chat</h1>
        <p class="hb-subtitle">Phoenix + ACP Gateway + Elixir SDK</p>
      </div>

      <div class="hb-topbar-actions">
        <%= if @active_thread do %>
          <span class="hb-provider-pill" data-provider={@active_thread.provider}>
            {String.upcase(@active_thread.provider)}
          </span>
        <% end %>

        <button
          type="button"
          class="hb-icon-btn mobile-only"
          phx-click="toggle_right_panel"
          title="Thread history"
        >
          <.icon name="hero-bars-3" class="h-5 w-5" />
        </button>
      </div>
    </header>
    """
  end

  attr :active_thread, :any, default: nil

  def left_panel(assigns) do
    ~H"""
    <section class="hb-panel-left">
      <div class="hb-panel-head">
        <h2>Session Inspector</h2>
      </div>

      <%= if @active_thread do %>
        <dl class="hb-inspector-grid">
          <div>
            <dt>Thread ID</dt>
            <dd class="mono">{@active_thread.id}</dd>
          </div>
          <div>
            <dt>Gateway Session</dt>
            <dd class="mono">{display_or_dash(@active_thread.gateway_session_key)}</dd>
          </div>
          <div>
            <dt>Provider</dt>
            <dd>{String.upcase(@active_thread.provider)}</dd>
          </div>
          <div>
            <dt>Approval Mode</dt>
            <dd>{@active_thread.approval_mode}</dd>
          </div>
          <div>
            <dt>Status</dt>
            <dd>{format_status(@active_thread.status)}</dd>
          </div>
          <div>
            <dt>Connected</dt>
            <dd>
              <span class={
                if @active_thread.connected, do: "hb-badge online", else: "hb-badge offline"
              }>
                {if @active_thread.connected, do: "online", else: "offline"}
              </span>
            </dd>
          </div>
          <div>
            <dt>Messages</dt>
            <dd>{length(@active_thread.messages)}</dd>
          </div>
          <div>
            <dt>Approvals</dt>
            <dd>{pending_approvals(@active_thread)}</dd>
          </div>
          <div>
            <dt>Last Error</dt>
            <dd>{display_or_dash(@active_thread.last_error)}</dd>
          </div>
        </dl>

        <div class="hb-action-row">
          <button
            type="button"
            class="hb-secondary-btn"
            phx-click="cancel_prompt"
            phx-value-thread_id={@active_thread.id}
          >
            Cancel Prompt
          </button>
          <button
            type="button"
            class="hb-secondary-btn"
            phx-click="close_thread"
            phx-value-thread_id={@active_thread.id}
          >
            Close Thread
          </button>
        </div>

        <div class="hb-event-box">
          <h3>Event Counters</h3>
          <%= if map_size(@active_thread.event_counts) == 0 do %>
            <p class="muted">No events yet.</p>
          <% else %>
            <ul>
              <li :for={{kind, count} <- Enum.sort(@active_thread.event_counts)}>
                <span>{kind}</span>
                <strong>{count}</strong>
              </li>
            </ul>
          <% end %>
        </div>
      <% else %>
        <p class="muted">Create a thread to initialize a gateway session.</p>
      <% end %>
    </section>
    """
  end

  attr :threads, :list, default: []
  attr :active_thread_id, :string, default: nil

  def right_panel(assigns) do
    ~H"""
    <aside class="hb-panel-right">
      <div class="hb-panel-head">
        <h2>Thread History</h2>
      </div>

      <.thread_create_form />

      <div class="hb-thread-list">
        <%= if @threads == [] do %>
          <p class="muted">No threads yet.</p>
        <% end %>

        <button
          :for={thread <- @threads}
          type="button"
          class={thread_item_class(thread.id == @active_thread_id)}
          phx-click="select_thread"
          phx-value-thread_id={thread.id}
        >
          <div class="hb-thread-line-1">
            <strong>{thread.title}</strong>
            <span class={if thread.connected, do: "dot online", else: "dot offline"}></span>
          </div>
          <div class="hb-thread-line-2">
            <span>{String.upcase(thread.provider)}</span>
            <span>{format_status(thread.status)}</span>
          </div>
        </button>
      </div>
    </aside>
    """
  end

  def thread_create_form(assigns) do
    ~H"""
    <form class="hb-new-thread" phx-submit="create_thread">
      <label for="provider">New Thread Provider</label>
      <div class="hb-new-thread-row">
        <select id="provider" name="provider" class="hb-select">
          <option value="codex">Codex</option>
          <option value="claude">Claude</option>
        </select>
        <button type="submit" class="hb-primary-btn">New</button>
      </div>
    </form>
    """
  end

  attr :active_thread, :any, default: nil
  attr :message_text, :string, default: ""

  def center_panel(assigns) do
    ~H"""
    <section class="hb-center">
      <div id="message-scroll" class="hb-message-scroll" phx-hook="AutoScroll">
        <%= if @active_thread && @active_thread.messages != [] do %>
          <.message_bubble
            :for={message <- @active_thread.messages}
            message={message}
            thread_id={@active_thread.id}
          />
        <% else %>
          <div class="hb-empty-state">
            <h3>Start a conversation</h3>
            <p>
              Create a thread on the right, choose `codex` or `claude`, and send a prompt.
            </p>
          </div>
        <% end %>
      </div>

      <form class="hb-composer" phx-submit="send_prompt" phx-change="update_message">
        <textarea
          name="message"
          rows="2"
          placeholder="Ask the agent..."
          value={@message_text}
          {if(is_nil(@active_thread), do: [disabled: true], else: [])}
        ></textarea>

        <div class="hb-composer-actions">
          <button
            type="submit"
            class="hb-primary-btn"
            {if(is_nil(@active_thread), do: [disabled: true], else: [])}
          >
            Send
          </button>
        </div>
      </form>
    </section>
    """
  end

  attr :message, :map, required: true
  attr :thread_id, :string, required: true

  def message_bubble(assigns) do
    ~H"""
    <article class={message_class(@message)}>
      <header>
        <strong>{format_role(@message.role)}</strong>
        <span class="muted">{format_message_status(@message.status)}</span>
      </header>

      <p>{@message.content}</p>

      <section
        :if={@message.role == :approval and @message.status == :pending}
        class="hb-approval-actions"
      >
        <button
          type="button"
          class="hb-primary-btn"
          phx-click="approve_request"
          phx-value-thread_id={@thread_id}
          phx-value-approval_ref={@message.approval_ref}
          phx-value-decision="allow"
        >
          Allow
        </button>
        <button
          type="button"
          class="hb-secondary-btn"
          phx-click="approve_request"
          phx-value-thread_id={@thread_id}
          phx-value-approval_ref={@message.approval_ref}
          phx-value-decision="deny"
        >
          Deny
        </button>
      </section>
    </article>
    """
  end

  defp display_or_dash(nil), do: "-"
  defp display_or_dash(""), do: "-"
  defp display_or_dash(value), do: value

  defp pending_approvals(%Thread{approvals: approvals}) do
    Enum.count(approvals, fn approval -> approval.status == :pending end)
  end

  defp format_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_status(status), do: to_string(status)

  defp format_role(:user), do: "You"
  defp format_role(:assistant), do: "Agent"
  defp format_role(:approval), do: "Approval"
  defp format_role(:system), do: "System"
  defp format_role(other), do: to_string(other)

  defp format_message_status(nil), do: ""

  defp format_message_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
  end

  defp message_class(%{role: :user}), do: "hb-message hb-user"
  defp message_class(%{role: :assistant}), do: "hb-message hb-assistant"
  defp message_class(%{role: :approval}), do: "hb-message hb-approval"
  defp message_class(_), do: "hb-message hb-system"

  defp thread_item_class(true), do: "hb-thread-item active"
  defp thread_item_class(false), do: "hb-thread-item"
end
