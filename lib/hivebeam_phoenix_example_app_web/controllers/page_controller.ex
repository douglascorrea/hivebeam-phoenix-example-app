defmodule HivebeamPhoenixExampleAppWeb.PageController do
  use HivebeamPhoenixExampleAppWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
  end
end
