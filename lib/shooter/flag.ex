defmodule Shooter.Flag do
  defstruct [color: nil]

  def build(color) when color in [:blue, :red], do: %__MODULE__{color: color}
end