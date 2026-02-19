defmodule HivebeamPhoenixExampleApp.Application do
  @moduledoc false

  use Application

  alias HivebeamPhoenixExampleApp.GatewayConfig

  @impl true
  def start(_type, _args) do
    :ok = GatewayConfig.require_token!()

    children = [
      HivebeamPhoenixExampleAppWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:hivebeam_phoenix_example_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HivebeamPhoenixExampleApp.PubSub},
      {Registry, keys: :unique, name: HivebeamPhoenixExampleApp.Chat.ClientRegistry},
      {HivebeamPhoenixExampleApp.Chat.ClientSupervisor, []},
      {HivebeamPhoenixExampleApp.Chat.ThreadStore, []},
      {HivebeamPhoenixExampleApp.Chat.SessionManager, []},
      HivebeamPhoenixExampleAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HivebeamPhoenixExampleApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HivebeamPhoenixExampleAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
