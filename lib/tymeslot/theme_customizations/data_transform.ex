defmodule Tymeslot.ThemeCustomizations.DataTransform do
  @moduledoc """
  Normalises a customisation (schema struct, atom- or string-keyed map of
  settings) to the string-keyed settings map that specs, tokens and saves work
  on, so no caller reads `m[:k] || m["k"]`.
  """

  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @spec to_settings(ThemeCustomizationSchema.t() | map() | nil) :: Spec.settings()
  def to_settings(nil), do: %{}
  def to_settings(%ThemeCustomizationSchema{settings: settings}), do: settings || %{}

  def to_settings(customization) when is_map(customization),
    do: Map.new(customization, fn {key, value} -> {to_string(key), value} end)
end
