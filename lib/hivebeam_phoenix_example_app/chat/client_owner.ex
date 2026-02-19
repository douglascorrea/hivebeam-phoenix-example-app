defmodule HivebeamPhoenixExampleApp.Chat.ClientOwner do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      thread_id: Keyword.fetch!(opts, :thread_id),
      manager: Keyword.fetch!(opts, :manager)
    }

    {:ok, state}
  end

  @impl true
  def handle_info(message, state) do
    send(state.manager, {:thread_client_event, state.thread_id, message})
    {:noreply, state}
  end
end
