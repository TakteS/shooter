defmodule Shooter.Server do
  defmodule State do
    defstruct [available_colors: [:blue, :red], names: %{}, game_field: nil, positions: nil, reason_of_finish: nil]
  end

  use GenServer

  alias Shooter.Warrior

  require Logger

  @field_size 500
  @field_units [:grass, :wall]

  @directions [:up, :down, :left, :right]

  @shooting_max_distance 3

  @inactive_timeout 60 * 3 * 1000 # 3 minutes

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id) |> String.replace("-", "-") |> String.to_atom() |> IO.inspect()

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

  def get_field(pid) do
    GenServer.call(pid, :get_field)
  end

  def bind_color(pid, name) do
    GenServer.call(pid, {:bind_color, name})
  end

  def get_warriors(pid) do
    GenServer.call(pid, :get_warriors)
  end

  def get_reason_of_finish(pid) do
    GenServer.call(pid, :get_reason_of_finish)
  end

  def move(pid, color, direction) when direction in @directions do
    GenServer.call(pid, {:move, color, direction})
  end

  def shoot(pid, color) do
    GenServer.call(pid, {:shoot, color})
  end

  def add_wall(pid, color) do
    GenServer.call(pid, {:add_wall, color})
  end

  def restart_game(pid) do
    GenServer.call(pid, :restart_game)
  end

  def handle_call(:get_field, _from, state) do
    {:reply, state.game_field, state, @inactive_timeout}
  end

  def handle_call({:bind_color, name}, _from, state) do
    if state.available_colors != [] do
      [color | rest_collors] = state.available_colors
      updated_state = %{state | available_colors: rest_collors, names: Map.put(state.names, name, color)}
      {:reply, color, updated_state, @inactive_timeout}
    else
      {:reply, {:error, :no_available_colors}, state, @inactive_timeout}
    end
  end

  def handle_call(:get_warriors, _from, state) do
    {:reply, state.names, state, @inactive_timeout}
  end

  def handle_call(:get_reason_of_finish, _from, state) do
    {:reply, state.reason_of_finish, state, @inactive_timeout}
  end

  def handle_call(:restart_game, _from, _state) do
    new_state = build_initial_state()
    {:reply, new_state.game_field, new_state, @inactive_timeout}
  end

  def handle_call({:move, color, direction}, _from, %State{game_field: field, positions: positions} = state) do
    current_position = positions[color] - 1
    warrior = Enum.at(field, current_position)

    {updated_field, updated_positions, reason_of_finish} =
      case {warrior.direction, direction} do
        {current, new} when current != new ->
          updated_warrior = Warrior.change_direction(warrior, direction)
          updated_field = List.replace_at(field, current_position, updated_warrior)
          Logger.debug("Warrior #{color} changed direction on #{direction}")
          {updated_field, positions, nil}

        {current, new} when current == new ->
          Logger.debug("Processing #{color} warrior moving #{new}")

          case can_be_transited(field, current_position, new) do
            {:ok, new_position} ->
              Logger.debug("New #{color} warrior position is #{new_position}")
              warrior_or_blood = warrior_or_blood(field, warrior, new_position)
              reason_of_finish = if warrior_or_blood == :blood, do: "#{color} warrior burned himself", else: nil

              updated_field =
                field
                |> List.replace_at(current_position, :grass)
                |> List.replace_at(new_position, warrior_or_blood)

              updated_positions = Map.put(positions, color, new_position + 1)
              {updated_field, updated_positions, reason_of_finish}

            :error ->
              {field, positions, nil}
          end
        _ ->
          {field, positions, nil}
      end

    updated_state = %{state | game_field: updated_field, positions: updated_positions, reason_of_finish: reason_of_finish}
    {:reply, updated_field, updated_state, @inactive_timeout}
  end

  def handle_call({:shoot, color}, _from, %State{game_field: field, positions: positions} = state) do
    current_position = positions[color] - 1
    warrior = Enum.at(field, current_position)

    {updated_field, reason_of_finish} =
      case do_shoot(field, current_position, warrior.direction) do
        {:wall, position} ->
          Logger.debug("Warrior #{color} shooted at wall at position #{position}")
          {List.replace_at(field, position, grass_or_fire()), nil}

        {:warrior, position} ->
          Logger.debug("Warrior #{color} killed his opponent!")
          {List.replace_at(field, position, :blood), "#{color} warrior killed an opponent"}

        _ ->
          Logger.debug("#{color} warrior's bullet didn't reach any target")
          {field, nil}
      end

    updated_state = %{state | game_field: updated_field, reason_of_finish: reason_of_finish}
    {:reply, updated_field, updated_state, @inactive_timeout}
  end

  def handle_call({:add_wall, color}, _from, %State{game_field: field, positions: positions} = state) do
    current_position = positions[color] - 1
    warrior = Enum.at(field, current_position)

    updated_field =
      case can_add_wall(field, current_position, warrior.direction) do
        {:ok, position} ->
          Logger.debug("Warrior #{color} added wall at position #{position}")
          List.replace_at(field, position, :wall)

        _ ->
          Logger.debug("#{color} warrior's cannot add wall at this position")
          field
      end

    updated_state = %{state | game_field: updated_field}
    {:reply, updated_field, updated_state, @inactive_timeout}
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
        Logger.debug("Warrior can't be transited")
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
        Logger.debug("Warrior can't add wall")
        :error
    end
  end

  defp valid_base_transition?(new_position, field), do: new_position in 0..(@field_size - 1) && Enum.at(field, new_position) in [:grass, :fire]

  defp valid_horizontal_transition?(position, new_position, :right), do: position < new_position && positions_in_same_line?(position, new_position)
  defp valid_horizontal_transition?(position, new_position, :left), do: position > new_position && positions_in_same_line?(position, new_position)
  defp valid_horizontal_transition?(_, _, _), do: true

  defp do_shoot(field, current_position, direction) do
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
      |> Enum.map(fn {%Warrior{}, position} -> {:warrior, position}; other -> other end)
      |> Enum.filter(fn
        {target, position} when target in [:warrior, :wall] ->
          case direction do
            dem when dem in [:left, :right] -> positions_in_same_line?(current_position, position)
            dem when dem == :up -> position >= 0 && current_position > position
            dem when dem == :down -> current_position < position
          end;
        _ -> false end)
      |> List.first()

    case shootable_targets do
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
    base_field = Enum.map(2..(@field_size - 1), fn _n -> Enum.random(@field_units) end)
    initial_field = [Warrior.build(:blue, :down)] ++ base_field ++ [Warrior.build(:red, :up)]

    inital_positions = %{blue: 1, red: @field_size}
    %State{game_field: initial_field, positions: inital_positions}
  end

  defp grass_or_fire(), do: Enum.random([:grass, :grass, :grass, :grass, :fire])

  defp warrior_or_blood(field, warrior, new_position) do
    case Enum.at(field, new_position) do
      :fire -> :blood
      _ -> warrior
    end
  end
end