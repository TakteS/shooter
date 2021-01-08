defmodule ShooterWeb.GameLive do
  use ShooterWeb, :live_view

  alias Shooter.Server

  require Logger

  @impl true
  def render(assigns) do
    ShooterWeb.GameLiveView.render("game_live.html", assigns)
  end

  @impl true
  def mount(_params, %{"name" => name, "session_id" => session_id, "user_session" => user_session}, socket) do
    {:ok, session_pid} = Server.start_link([session_id: session_id])
    {field, scores} = Server.get_field_and_scores(session_pid)

    with true <- connected?(socket),
         color when color in [:blue, :red] <- Server.pick_color(session_pid, name, user_session) do
      Phoenix.PubSub.subscribe(Shooter.PubSub, topic(session_id))
      players = Server.get_players(session_pid)

      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(session_id), "player_joined")
      Logger.info("User #{name} joined to #{session_id} as #{color} player")
      {:ok, assign(socket, is_loaded: true, game_field: field, scores: scores, field_width: 20, color: color, players: players, pid: session_pid, session_id: session_id, is_game_finished: nil), temporary_assigns: [game_field: []]}
    else
      :no_available_colors ->
        {:ok, redirect(socket, to: "/")}
      _ ->
        {:ok, assign(socket, is_loaded: false)}
    end
  end
  def mount(_, _, socket) do
    {:ok, redirect(socket, to: "/")}
  end

  @impl true
  def handle_event("update_field", %{"key" => "Arrow" <> arrow_direction}, socket) do
    fn ->
      direction = parse_direction(arrow_direction)
      updated_field = Server.move(socket.assigns.pid, socket.assigns.color, direction)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), {"update_field_units", updated_field})
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("update_field", %{"key" => " "}, socket) do
    fn ->
      updated_field = Server.shoot(socket.assigns.pid, socket.assigns.color)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), {"update_field_units", updated_field})
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("update_field", %{"key" => "Shift"}, socket) do
    fn ->
      updated_field = Server.add_wall(socket.assigns.pid, socket.assigns.color)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), {"update_field_units", updated_field})
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("restart_game", _value, socket) do
    {updated_field, scores} = Server.restart_game(socket.assigns.pid)
    Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), {"update_field_units", updated_field})
    {:noreply, assign(socket, game_field: updated_field, scores: scores, is_game_finished: nil)}
  end
  def handle_event("update_field", _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({"update_field_units", new_units}, socket) do
    {:noreply, assign(socket, game_field: new_units)}
  end
  def handle_info("player_joined", socket) do
    players = Server.get_players(socket.assigns.pid)
    {:noreply, assign(socket, players: players, is_game_finished: nil)}
  end
  def handle_info(_, socket), do: {:noreply, socket}

  defp parse_direction("Up"), do: :up
  defp parse_direction("Down"), do: :down
  defp parse_direction("Left"), do: :left
  defp parse_direction("Right"), do: :right

  defp topic(session_id), do: "game_#{session_id}"

  defp check_game_finish_and_process_action(action, socket) do
    reason_of_finish = Server.get_reason_of_finish(socket.assigns.pid)

    if reason_of_finish do
      {:noreply, assign(socket, is_game_finished: true, reason_of_finish: reason_of_finish)}
    else
      action.()
    end
  end
end
