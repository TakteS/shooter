defmodule Shooter.Player do
  defstruct [color: nil, direction: nil]

  @colors [:blue, :red]
  @directions [:up, :down, :left, :right]

  def build(color, direction) when color in @colors and direction in @directions do
    %__MODULE__{color: color, direction: direction}
  end

  def change_direction(%__MODULE__{} = player, new_direction) when new_direction in @directions do
    %{player | direction: new_direction}
  end

  def set_name(%__MODULE__{} = player, name) when is_binary(name) do
    %{player | name: name}
  end
end