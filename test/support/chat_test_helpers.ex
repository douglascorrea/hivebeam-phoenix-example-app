defmodule HivebeamPhoenixExampleApp.TestSupport.ChatTestHelpers do
  @moduledoc false

  alias HivebeamPhoenixExampleApp.Chat.SessionManager
  alias HivebeamPhoenixExampleApp.Chat.ThreadStore

  @app :hivebeam_phoenix_example_app

  @spec reset_runtime(module()) :: :ok
  def reset_runtime(client_module) when is_atom(client_module) do
    clear_threads()
    restart_session_manager(client_module)
    :ok
  end

  @spec clear_threads() :: :ok
  def clear_threads do
    threads =
      try do
        SessionManager.list_threads()
      catch
        :exit, _ -> []
      end

    Enum.each(threads, fn thread ->
      _ =
        try do
          SessionManager.close_thread(thread.id)
        catch
          :exit, _ -> {:error, :session_manager_down}
        end
    end)

    _ = ThreadStore.clear()
    :ok
  end

  @spec restart_session_manager(module()) :: :ok
  def restart_session_manager(client_module) when is_atom(client_module) do
    Application.put_env(@app, :hivebeam_client_module, client_module)
    supervisor = HivebeamPhoenixExampleApp.Supervisor
    child_id = HivebeamPhoenixExampleApp.Chat.SessionManager

    case Supervisor.terminate_child(supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
    end

    case Supervisor.delete_child(supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
    end

    {:ok, _pid} =
      Supervisor.start_child(supervisor, {SessionManager, [client_module: client_module]})

    :ok
  end

  @spec runtime_client_pid(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def runtime_client_pid(thread_id) when is_binary(thread_id) do
    state = :sys.get_state(SessionManager)

    case get_in(state, [:runtimes, thread_id, :client_pid]) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @spec eventually((-> any()), pos_integer(), pos_integer()) :: :ok
  def eventually(fun, attempts \\ 50, delay_ms \\ 50) when is_function(fun, 0) and attempts > 0 do
    do_eventually(fun, attempts, delay_ms)
  end

  defp do_eventually(fun, attempts, delay_ms) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts > 1 do
        Process.sleep(delay_ms)
        do_eventually(fun, attempts - 1, delay_ms)
      else
        reraise(error, __STACKTRACE__)
      end
  end
end
