defmodule ShooterWeb.LobbyController do
  use ShooterWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def create(conn, %{"name" => name} = params) do
    session_id = Map.get(params, "session_id")
    user_session = UUID.uuid4()
    session_id = if session_id == "", do: UUID.uuid4(), else: session_id

    conn =
      conn
      |> Plug.Conn.put_session(:name, name)
      |> Plug.Conn.put_session(:session_id, session_id)
      |> Plug.Conn.put_session(:user_session, user_session)

    redirect(conn, to: Routes.game_path(conn, :index, session_id))
  end
end