defmodule ShooterWeb.GameLive do
  use ShooterWeb, :live_view

  alias Shooter.{Server, Warrior}

  require Logger

  @impl true
  def render(assigns) do
    ~L"""
    <div id="game" phx-window-keyup="update_field">
      <%= if @is_game_finished do %>
        <b>Game was finished because of <%= @reason_of_finish %></b>
        <br />
        <button phx-click="restart_game">Start new!</button>
      <% else %>
        <%= if @game_field == [] do %>
          You cannot join this game.
        <% else %>
          Link to join game: <%= Routes.lobby_url(ShooterWeb.Endpoint, :index, @session_id) %>
          <br />
          <br />
          <%= for field_units <- Enum.chunk_every(@game_field, @field_width) do %>
            <div class="field-line">
              <%= for unit <- field_units do %>
                <%= case unit do %>
                  <% :grass -> %> <img src="<%= Routes.static_path(ShooterWeb.Endpoint, "/images/grass.png") %>" height="35" width="35" class="field-unit"/>
                  <% :wall -> %> <img src="<%= Routes.static_path(ShooterWeb.Endpoint, "/images/wall.png") %>" height="35" width="35" class="field-unit"/>
                  <% :blood -> %> <img src="<%= Routes.static_path(ShooterWeb.Endpoint, "/images/blood.png") %>" height="35" width="35" class="field-unit"/>
                  <% :fire -> %> <img src="<%= Routes.static_path(ShooterWeb.Endpoint, "/images/fire.png") %>" height="35" width="35" class="field-unit"/>
                  <% %Warrior{color: color, direction: direction} -> %> <img src="<%= Routes.static_path(ShooterWeb.Endpoint, "/images/#{color}_warrior_#{direction}.png") %>" height="35" width="35" class="field-unit"/>
                <% end %>
              <% end %>
            </div>
          <% end %>
        </div>
        <div id="warriors">
          Warriors:
          <br />
          <%= for {color, name} <- @warriors do %>
            <b><%= color %>: </b><%= name %>
            <br />
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(_params, %{"name" => name, "session_id" => session_id}, socket) do
    {:ok, session_pid} = Server.start_link([session_id: session_id])

    with true <- connected?(socket),
         color when color in [:blue, :red] <- Server.bind_color(session_pid, name) do
      Phoenix.PubSub.subscribe(Shooter.PubSub, topic(session_id))

      field = Server.get_field(session_pid)
      warriors = Server.get_warriors(session_pid)

      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(session_id), "player_joined")
      Logger.info("User #{name} joined to #{session_id} as #{color} warrior")
      {:ok, assign(socket, game_field: field, field_width: 20, color: color, warriors: warriors, pid: session_pid, session_id: session_id, is_game_finished: nil)}
    else
      _ ->
        Logger.info("User #{name} joined as guest to #{session_id}")
        {:ok, assign(socket, game_field: [], field_width: 20, warriors: [], is_game_finished: nil)}
    end
  end
  def mount(_, _, socket) do
    {:ok, assign(socket, game_field: [], field_width: 20, warriors: [], is_game_finished: nil)}
  end

  @impl true
  def handle_event("update_field", %{"key" => "Arrow" <> arrow_direction}, socket) do
    fn ->
      direction = parse_direction(arrow_direction)
      updated_field = Server.move(socket.assigns.pid, socket.assigns.color, direction)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), "update_field")
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("update_field", %{"key" => " "}, socket) do
    fn ->
      updated_field = Server.shoot(socket.assigns.pid, socket.assigns.color)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), "update_field")
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("update_field", %{"key" => "Shift"}, socket) do
    fn ->
      updated_field = Server.add_wall(socket.assigns.pid, socket.assigns.color)
      Phoenix.PubSub.broadcast(Shooter.PubSub, topic(socket.assigns.session_id), "update_field")
      {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
    end
    |> check_game_finish_and_process_action(socket)
  end
  def handle_event("restart_game", _value, socket) do
    updated_field = Server.restart_game(socket.assigns.pid)
    {:noreply, assign(socket, game_field: updated_field, is_game_finished: nil)}
  end
  def handle_event("update_field", _, socket), do: {:noreply, socket}

  @impl true
  def handle_info("update_field", socket) do
    current_field = Server.get_field(socket.assigns.pid)
    {:noreply, assign(socket, game_field: current_field, is_game_finished: nil)}
  end
  def handle_info("player_joined", socket) do
    warriors = Server.get_warriors(socket.assigns.pid)
    {:noreply, assign(socket, warriors: warriors, is_game_finished: nil)}
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
