defmodule TymeslotWeb.Themes.Core.Axes do
  @moduledoc """
  The seven design axes a booking theme is described by, and the values
  each one takes. Two themes that share most values tell the same story,
  whatever their colours; the rubric test (`theme_rubric_test.exs`) holds
  every pair of shipped themes to three differences.

  | Axis | Says |
  |---|---|
  | `flow` | how the journey meets the screen |
  | `entry` | what the visitor is asked first |
  | `spatial` | the page's layout |
  | `time_view` | how free times are shown |
  | `conversion` | what persuades the visitor to book |
  | `voice` | how the page speaks |
  | `surface` | the material it is drawn in |

  A theme declares one value on each with `use TymeslotWeb.Themes.Core.Theme,
  axes: [...]`, which checks the declaration while the theme compiles. This
  module is pure data with no dependency for that reason: every theme module
  depends on it at compile time.
  """

  @values [
    flow: [:paged_wizard, :two_screen, :continuous, :conversation, :time_first],
    entry: [:meeting_type_first, :time_first, :person_first, :questions_first],
    spatial: [
      :centred_card,
      :wide_card,
      :split_card,
      :split_screen,
      :full_bleed_editorial,
      :mobile_first_stack,
      :chat_column,
      :typographic_grid
    ],
    time_view: [:month_grid, :week_strip, :week_grid, :next_slots, :agenda_index, :day_chips],
    conversion: [:none, :atmosphere, :bio_and_cover, :host_video, :work_samples],
    voice: [:neutral, :polished, :evocative, :personal, :direct, :brisk, :terse, :warm],
    surface: [
      :glass,
      :flat_light_card,
      :flat_bold,
      :editorial_print,
      :utilitarian,
      :brutalist,
      :soft_bubbles
    ]
  ]

  @names Keyword.keys(@values)

  @typedoc "One of the seven axes."
  @type axis :: :flow | :entry | :spatial | :time_view | :conversion | :voice | :surface

  @doc "The seven axes, in their canonical order."
  @spec names() :: [axis()]
  def names, do: @names

  @doc "The values `axis` takes. Raises `KeyError` for an axis that does not exist."
  @spec values(axis()) :: [atom()]
  def values(axis), do: Keyword.fetch!(@values, axis)

  @doc "The axes on which two themes' declarations differ, in the canonical order."
  @spec differences(keyword(), keyword()) :: [axis()]
  def differences(axes, other), do: Enum.reject(@names, &(axes[&1] == other[&1]))

  @doc """
  Checks a theme's declaration and returns it in the canonical order: a
  keyword list naming each of the seven axes once, each with one of its
  values. Raises `ArgumentError` naming what is wrong.
  """
  @spec validate!(term()) :: keyword()
  def validate!(axes) when is_list(axes) do
    if not Keyword.keyword?(axes), do: raise(ArgumentError, not_a_keyword_list(axes))

    check_names!(Keyword.keys(axes))
    check_values!(axes)
    Enum.map(@names, &{&1, Keyword.fetch!(axes, &1)})
  end

  def validate!(axes), do: raise(ArgumentError, not_a_keyword_list(axes))

  defp not_a_keyword_list(axes) do
    "the :axes of a theme must be a literal keyword list naming the seven axes " <>
      "#{inspect(@names)}, got: #{inspect(axes)}"
  end

  defp check_names!(given) do
    missing = @names -- given
    extra = given -- @names

    if missing != [] or extra != [] do
      raise ArgumentError,
            "the :axes of a theme must name each of #{inspect(@names)} once; " <>
              "missing: #{inspect(missing)}, unknown or repeated: #{inspect(extra)}"
    end
  end

  defp check_values!(axes) do
    case Enum.reject(axes, fn {axis, value} -> value in values(axis) end) do
      [] ->
        :ok

      wrong ->
        raise ArgumentError,
              "the :axes of a theme take one of each axis's values (Axes.values/1); " <>
                Enum.map_join(wrong, ", ", fn {axis, value} ->
                  "#{axis}: #{inspect(value)} is not one of #{inspect(values(axis))}"
                end)
    end
  end
end
