# This code is very stupid. I warned you.
defmodule Shooter.Server do
  defmodule State do
    defstruct [scores: %{blue: 0, red: 0}, available_colors: [:blue, :red], players: %{}, game_field: nil, positions: nil, reason_of_finish: nil]
  end

  defmodule Unit do
    defstruct [entity: nil, id: nil]

    def build(entity, id), do: %__MODULE__{entity: entity, id: id}
  end

  use GenServer

  alias Shooter.{Player, Flag}

  require Logger

  @field_size 400
  @field_units [:grass, :wall]

  @directions [:up, :down, :left, :right]

  @shooting_max_distance 3

  @inactive_timeout 60 * 3 * 1000 # 3 minutes

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id) |> String.replace("-", "-") |> String.to_atom()

    case Process.whereis(session_id) do
      nil ->
        GenServer.start_link(__MODULE__, build_initial_state(), name: session_id)
      pid ->
        {:ok, pid}
    end
  end

  def init(state) do
    {:ok, state, @inactive_timeout}
  end

  def get_field_and_scores(pid), do: GenServer.call(pid, :get_field_and_scores)

  def get_players(pid), do: GenServer.call(pid, :get_players)

  def get_reason_of_finish(pid), do: GenServer.call(pid, :get_reason_of_finish)

  def pick_color(pid, name, user_session), do: GenServer.call(pid, {:pick_color, name, user_session})

  def move(pid, color, direction) when direction in @directions do
    GenServer.call(pid, {:move, color, direction})
  end

  def shoot(pid, color), do: GenServer.call(pid, {:shoot, color})

  def add_wall(pid, color), do: GenServer.call(pid, {:add_wall, color})

  def restart_game(pid), do: GenServer.call(pid, :restart_game)

  def handle_call(:get_field_and_scores, _from, state) do
    {:reply, {state.game_field, state.scores}, state, @inactive_timeout}
  end

  def handle_call(:get_players, _from, state) do
    players = Enum.map(state.players, fn {_k, %{color: color, name: name}} -> {color, name} end)
    {:reply, players, state, @inactive_timeout}
  end

  def handle_call(:get_reason_of_finish, _from, state) do
    {:reply, state.reason_of_finish, state, @inactive_timeout}
  end

  def handle_call(:get_scores, _from, state) do
    {:reply, state.scores, state}
  end

  def handle_call({:pick_color, name, user_session}, _from, state) do
    {color, rest_collors, updated_players} =
      with {:ok, color} <- check_player_already_joined(user_session, state.players) do
        {color, state.available_colors, state.players}
      else
        {:error, :not_joined} ->
          cond do
            state.available_colors != [] ->
              [color | rest_collors] = state.available_colors
              {color, rest_collors, Map.put(state.players, user_session, %{name: name, color: color})}

            true ->
              {:no_available_colors, [], state.players}
          end
      end

    updated_state = %{state | available_colors: rest_collors, players: updated_players}
    {:reply, color, updated_state, @inactive_timeout}
  end

  def handle_call(:restart_game, _from, state) do
    new_state = build_initial_state(state.players, state.scores, state.available_colors)
    {:reply, {new_state.game_field, state.scores}, new_state, @inactive_timeout}
  end

  def handle_call({:move, color, direction}, _from, %State{game_field: field, positions: positions, scores: scores} = state) do
    current_position = positions[color] - 1
    player_unit = Enum.at(field, current_position)
    player = player_unit.entity

    with %Player{} <- player do
      {updated_field, updated_positions, reason_of_finish, updated_scores} =
        case {player.direction, direction} do
          {current, new} when current != new ->
            updated_player = %{player_unit | entity: Player.change_direction(player, direction)}
            updated_field = List.replace_at(field, current_position, updated_player)
            Logger.debug("Player #{color} changed direction on #{direction}")
            {updated_field, positions, nil, scores}

          {current, new} when current == new ->
            Logger.debug("Processing #{color} player moving #{new}")

            case can_be_transited(field, current_position, new) do
              {:ok, new_position} ->
                Logger.debug("New #{color} player position is #{new_position}")
                player_or_blood = player_or_blood(field, player, new_position)
                reason_of_finish = if player_or_blood.entity == :blood, do: "#{color} player burned himself", else: nil
                updated_scores = if player_or_blood.entity == :blood, do: Map.update!(scores, color, & &1 - 1), else: scores

                updated_field =
                  field
                  |> List.replace_at(current_position, Unit.build(:grass, current_position))
                  |> List.replace_at(new_position, player_or_blood)

                updated_positions = Map.put(positions, color, new_position + 1)
                {updated_field, updated_positions, reason_of_finish, updated_scores}

              :error ->
                {field, positions, nil, scores}
            end
          _ ->
            {field, positions, nil, scores}
        end

      updated_state = %{state | game_field: updated_field, positions: updated_positions, reason_of_finish: reason_of_finish, scores: updated_scores}
      {:reply, updated_field -- field, updated_state, @inactive_timeout}
    else
      _ ->
        {:reply, field, state, @inactive_timeout}
    end
  end

  def handle_call({:shoot, color}, _from, %State{game_field: field, positions: positions, scores: scores} = state) do
    current_position = positions[color] - 1
    player_unit = Enum.at(field, current_position)
    player = player_unit.entity

    {updated_field, reason_of_finish, updated_scores} =
      case do_shoot(player.color, field, current_position, player.direction) do
        {:wall, position} ->
          Logger.debug("Player #{color} shooted at wall at position #{position}")
          {List.replace_at(field, position, grass_or_fire(position)), nil, scores}

        {:player, position} ->
          Logger.debug("Player #{color} killed his opponent!")
          updated_scores = Map.update!(scores, color, & &1 + 1)
          {List.replace_at(field, position, Unit.build(:blood, position)), "#{color} player killed an opponent", updated_scores}

        {:flag, position} ->
          Logger.debug("Player #{color} captured opponent's flag!")
          updated_scores = Map.update!(scores, color, & &1 + 1)
          {List.replace_at(field, position, Unit.build(:grass, position)), "#{color} player captured opponent's flag", updated_scores}

        _ ->
          Logger.debug("#{color} player's bullet didn't reach any target")
          {field, nil, scores}
      end

    updated_state = %{state | game_field: updated_field, reason_of_finish: reason_of_finish, scores: updated_scores}
    {:reply, updated_field -- field, updated_state, @inactive_timeout}
  end

  def handle_call({:add_wall, color}, _from, %State{game_field: field, positions: positions} = state) do
    current_position = positions[color] - 1
    player_unit = Enum.at(field, current_position)
    player = player_unit.entity

    updated_field =
      case can_add_wall(field, current_position, player.direction) do
        {:ok, position} ->
          Logger.debug("Player #{color} added wall at position #{position}")
          List.replace_at(field, position, Unit.build(:wall, position))

        _ ->
          Logger.debug("#{color} player's cannot add wall at this position")
          field
      end

    updated_state = %{state | game_field: updated_field}
    {:reply, updated_field -- field, updated_state, @inactive_timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def terminate(reason, _state) do
    reason
  end

  defp can_be_transited(field, current_position, direction) do
    new_position =
      case direction do
        :left -> current_position - 1
        :right -> current_position + 1
        :down -> current_position + 20
        :up -> current_position - 20
      end

    with true <- valid_base_transition?(new_position, field),
         true <- valid_horizontal_transition?(current_position, new_position, direction) do
      {:ok, new_position}
    else
      _ ->
        Logger.debug("Player can't be transited")
        :error
    end
  end

  defp can_add_wall(field, current_position, direction) do
    new_position =
      case direction do
        :left -> current_position - 1
        :right -> current_position + 1
        :down -> current_position + 20
        :up -> current_position - 20
      end

    with true <- valid_base_transition?(new_position, field),
         true <- valid_horizontal_transition?(current_position, new_position, direction) do
      {:ok, new_position}
    else
      _ ->
        Logger.debug("Player can't add wall")
        :error
    end
  end

  defp valid_base_transition?(new_position, field), do: new_position in 0..(@field_size - 1) && Enum.at(field, new_position).entity in [:grass, :fire]

  defp valid_horizontal_transition?(position, new_position, :right), do: position < new_position && positions_in_same_line?(position, new_position)
  defp valid_horizontal_transition?(position, new_position, :left), do: position > new_position && positions_in_same_line?(position, new_position)
  defp valid_horizontal_transition?(_, _, _), do: true

  defp do_shoot(color, field, current_position, direction) do
    possible_tagtets =
      case direction do
        :left ->
          Enum.map((current_position - @shooting_max_distance)..(current_position - 1), fn n -> {Enum.at(field, n), n} end) |> Enum.reverse()

        :right ->
          Enum.map((current_position + 1)..(current_position + @shooting_max_distance), fn n -> {Enum.at(field, n), n} end)

        :down ->
          Enum.map(1..@shooting_max_distance, fn n ->
            pos = current_position + (n * 20)
            {Enum.at(field, pos), pos}
          end)

        :up ->
          Enum.map(1..@shooting_max_distance, fn n ->
            pos = current_position - (n * 20)
            {Enum.at(field, pos), pos}
          end)
      end

    shootable_targets =
      possible_tagtets
      |> Enum.map(fn {%Unit{entity: %Player{}}, position} -> {:player, position};
                     {%Unit{entity: %Flag{color: flag_color}}, position} -> (if flag_color != color, do: {:flag, position}, else: {:own_flag, position});
                     {%Unit{entity: entity}, position} -> {entity, position};
                     other -> other
      end)
      |> Enum.filter(fn
        {target, position} when target in [:player, :wall, :flag] ->
          case direction do
            dem when dem in [:left, :right] -> positions_in_same_line?(current_position, position)
            dem when dem == :up -> position >= 0 && current_position > position
            dem when dem == :down -> current_position < position
          end;
        _ -> false end)

    case List.first(shootable_targets) do
      nil -> :no_targets
      target -> target
    end
  end

  def positions_in_same_line?(current_position, target_position) when current_position >= 0 and target_position >= 0 do
    line_number_by_position(current_position) == line_number_by_position(target_position)
  end
  def positions_in_same_line?(_, _), do: false

  defp line_number_by_position(position), do: div(position, 20)

  defp build_initial_state() do
    build_initial_state(%{}, %{blue: 0, red: 0}, [:blue, :red])
  end

  defp build_initial_state(players, scores, available_colors) do
    base_field = Enum.map(3..(@field_size - 2), fn _n -> Enum.random(@field_units) end)
    initial_field =
      [Flag.build(:blue), Player.build(:blue, :down)] ++ base_field ++ [Player.build(:red, :up), Flag.build(:red)]
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> Unit.build(e, i) end)

    inital_positions = %{blue: 2, red: @field_size - 1}
    %State{game_field: initial_field, positions: inital_positions, players: players, scores: scores, available_colors: available_colors}
  end

  defp grass_or_fire(position) do
    grass = Unit.build(:grass, position)
    fire = Unit.build(:fire, position)

    Enum.random([grass, grass, grass, grass, fire])
  end

  defp player_or_blood(field, player, new_position) do
    case Enum.at(field, new_position) do
      %Unit{entity: :fire} -> Unit.build(:blood, new_position)
      _ -> Unit.build(player, new_position)
    end
  end

  defp check_player_already_joined(user_session, players) do
    case Map.get(players, user_session) do
      %{color: color} -> {:ok, color}
      _ -> {:error, :not_joined}
    end
  end
end