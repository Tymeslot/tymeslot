defmodule Tymeslot.ThemeCustomizations.Options.CalendarView do
  @moduledoc """
  The calendar view option: a month or a week. Stored as the `calendar_view`
  setting; nothing stored (or a value it does not know) means the group's
  `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :calendar_view, module:
  Options.CalendarView, default: "month"}`. It writes no custom property.
  `media/2` hands the choice to `Tokens.media` as `:calendar_view`, the same
  way `Options.Logo` hands over its logo, and a theme's schedule step reads
  `media[:calendar_view]` to render a month calendar to pick a day from, or a
  week of free times at once.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Spec

  @behaviour OptionGroup

  @types %{calendar_view: :string}
  @choices ~w(month week)

  @typedoc "A calendar view group: the view a page has until the organiser picks another."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the calendar view stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the calendar view, refusing anything but month and week."
  @impl OptionGroup
  def changeset(changeset, attrs, _group) do
    changeset
    |> cast(attrs, [:calendar_view])
    |> validate_inclusion(:calendar_view, @choices)
  end

  @doc "The changes a calendar view choice (`\"calendar_view\"`) makes; `:error` for any other field."
  @impl OptionGroup
  def changes("calendar_view", value, _group), do: {:ok, %{"calendar_view" => value}}
  def changes(_field, _value, _group), do: :error

  @doc "The choices, in the order the dashboard offers them."
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc "The stored calendar view, else the group's default."
  @spec choice(Spec.settings(), group()) :: String.t()
  def choice(settings, %{default: default}) do
    case settings["calendar_view"] do
      view when view in @choices -> view
      _unset -> default
    end
  end

  @doc "The calendar view's part of a spec's media (`OptionGroup.media/2`): the choice, as `:calendar_view`."
  @impl OptionGroup
  @spec media(Spec.settings(), group()) :: %{calendar_view: String.t()}
  def media(settings, group), do: %{calendar_view: choice(settings, group)}
end
