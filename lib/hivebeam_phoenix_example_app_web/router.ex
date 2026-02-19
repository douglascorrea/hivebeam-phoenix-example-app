defmodule HivebeamPhoenixExampleAppWeb.Router do
  use HivebeamPhoenixExampleAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HivebeamPhoenixExampleAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HivebeamPhoenixExampleAppWeb do
    pipe_through :browser

    live "/chat", ChatLive
    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", HivebeamPhoenixExampleAppWeb do
  #   pipe_through :api
  # end
end
