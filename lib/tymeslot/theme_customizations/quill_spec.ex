defmodule Tymeslot.ThemeCustomizations.QuillSpec do
  @moduledoc """
  Customisation spec for Quill: a colour palette and every background kind,
  defaulting to the Aurora gradient.
  """

  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec

  # Every shipped preset. A preset added to the catalogue reaches this theme
  # only when listed here. The schemes are in the order the onboarding wizard
  # and the dashboard show them; the background lists are sorted, the order
  # their pickers have always shown.
  @schemes ~w(default turquoise purple sunset ocean forest rose monochrome)
  @gradients ~w(gradient_1 gradient_2 gradient_3 gradient_4 gradient_5 gradient_6 gradient_7 gradient_8)
  @images ~w(preset:artistic-studio preset:elegant-still-life preset:ocean-sunset preset:rustic-farmhouse preset:space-satellite)
  @videos ~w(preset:blue-wave preset:dancing-girl preset:leaves preset:light-green preset:rhythm-default preset:space)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: @schemes},
      %{
        key: :background,
        module: Background,
        kinds: [:gradient, :color, :image, :video],
        gradients: @gradients,
        images: @images,
        videos: @videos
      }
    ]

  @impl Spec
  def defaults,
    do: %{color_scheme: "default", background_type: "gradient", background_value: "gradient_1"}
end
