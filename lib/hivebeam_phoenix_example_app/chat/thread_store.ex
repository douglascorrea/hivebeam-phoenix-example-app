defmodule HivebeamPhoenixExampleApp.Chat.ThreadStore do
  @moduledoc false
  use GenServer

  alias HivebeamPhoenixExampleApp.Chat.Thread

  @table __MODULE__.Table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_thread(map() | keyword()) :: {:ok, Thread.t()}
  def create_thread(attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_thread, attrs})
  end

  @spec list_threads() :: [Thread.t()]
  def list_threads do
    GenServer.call(__MODULE__, :list_threads)
  end

  @spec get_thread(String.t()) :: {:ok, Thread.t()} | {:error, :not_found}
  def get_thread(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:get_thread, thread_id})
  end

  @spec update_thread(String.t(), (Thread.t() -> Thread.t())) ::
          {:ok, Thread.t()} | {:error, :not_found}
  def update_thread(thread_id, updater) when is_binary(thread_id) and is_function(updater, 1) do
    GenServer.call(__MODULE__, {:update_thread, thread_id, updater})
  end

  @spec put_thread(Thread.t()) :: {:ok, Thread.t()}
  def put_thread(%Thread{} = thread) do
    GenServer.call(__MODULE__, {:put_thread, thread})
  end

  @spec delete_thread(String.t()) :: :ok
  def delete_thread(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:delete_thread, thread_id})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:create_thread, attrs}, _from, state) do
    thread = Thread.new(attrs)
    true = :ets.insert(state.table, {thread.id, thread})
    {:reply, {:ok, thread}, state}
  end

  def handle_call(:list_threads, _from, state) do
    threads =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, thread} -> thread end)
      |> Enum.sort_by(&sort_key/1, {:desc, DateTime})

    {:reply, threads, state}
  end

  def handle_call({:get_thread, thread_id}, _from, state) do
    case :ets.lookup(state.table, thread_id) do
      [{^thread_id, thread}] -> {:reply, {:ok, thread}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:put_thread, %Thread{} = thread}, _from, state) do
    true = :ets.insert(state.table, {thread.id, thread})
    {:reply, {:ok, thread}, state}
  end

  def handle_call({:update_thread, thread_id, updater}, _from, state) do
    case :ets.lookup(state.table, thread_id) do
      [{^thread_id, %Thread{} = thread}] ->
        updated = updater.(thread) |> Thread.touch()
        true = :ets.insert(state.table, {thread_id, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete_thread, thread_id}, _from, state) do
    _ = :ets.delete(state.table, thread_id)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    _ = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  defp sort_key(%Thread{updated_at: updated_at}) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, datetime, _offset} -> datetime
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp sort_key(_thread), do: ~U[1970-01-01 00:00:00Z]
end
