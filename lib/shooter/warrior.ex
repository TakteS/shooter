defmodule Shooter.Warrior do
  defstruct [name: nil, color: nil, direction: nil]

  @colors [:blue, :red]
  @directions [:up, :down, :left, :right]

  def build(color, direction) when color in @colors and direction in @directions do
    %__MODULE__{color: color, direction: direction}
  end

  def change_direction(%__MODULE__{} = warrior, new_direction) when new_direction in @directions do
    %{warrior | direction: new_direction}
  end

  def set_name(%__MODULE__{} = warrior, name) when is_binary(name) do
    %{warrior | name: name}
  end
end