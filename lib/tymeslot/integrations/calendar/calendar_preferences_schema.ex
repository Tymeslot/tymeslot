defmodule Tymeslot.Integrations.Calendar.CalendarPreferencesSchema do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          default_view: String.t(),
          hidden_integration_ids: [integer()],
          week_start_day: String.t(),
          time_format: String.t() | nil,
          show_week_numbers: boolean(),
          show_weekends: boolean(),
          desktop_reminders_enabled: boolean(),
          density: String.t(),
          fold_night: boolean(),
          focus_mode: boolean(),
          bookable_layer: boolean(),
          bookable_meeting_type_id: integer() | nil,
          active_calendar_set_id: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_preferences" do
    belongs_to :user, Tymeslot.Auth.UserSchema
    field :default_view, :string, default: "week"
    field :hidden_integration_ids, {:array, :integer}, default: []
    field :week_start_day, :string, default: "monday"
    # nil means "never chosen", which defers to the organiser's language.
    # Resolve it through `TimeFormat.resolve/2` rather than reading it raw.
    field :time_format, :string
    field :show_week_numbers, :boolean, default: false
    field :show_weekends, :boolean, default: true
    field :desktop_reminders_enabled, :boolean, default: false
    # How the calendar's grid is drawn, and whether focus mode hides the
    # dashboard menu (`TymeslotWeb.Dashboard.CalendarFocus`).
    field :density, :string, default: "comfortable"
    field :fold_night, :boolean, default: true
    field :focus_mode, :boolean, default: false

    # The calendar's bookable-times layer: whether it shows, and the
    # meeting type it shows (nil: the first active one). See
    # `Tymeslot.CalendarGrid.LayerPreferences`.
    field :bookable_layer, :boolean, default: true
    belongs_to :bookable_meeting_type, Tymeslot.MeetingTypes.MeetingTypeSchema

    # The calendar set the calendar shows (nil: none, the organiser's
    # own hidden choices apply). A plain id rather than `belongs_to`, so this
    # module does not depend on `Tymeslot.CalendarGrid`; see
    # `Tymeslot.CalendarGrid.CalendarSets`.
    field :active_calendar_set_id, :id

    timestamps(type: :utc_datetime)
  end

  @valid_views ~w(week day month agenda)
  @valid_week_starts ~w(monday sunday)
  @valid_time_formats TimeFormat.formats()
  @valid_densities ~w(comfortable compact)

  @doc "The densities a calendar grid can be drawn in."
  @spec densities() :: [String.t()]
  def densities, do: @valid_densities

  @castable_fields [
    :user_id,
    :default_view,
    :hidden_integration_ids,
    :week_start_day,
    :time_format,
    :show_week_numbers,
    :show_weekends,
    :desktop_reminders_enabled,
    :density,
    :fold_night,
    :focus_mode,
    :bookable_layer,
    :bookable_meeting_type_id,
    :active_calendar_set_id
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, @castable_fields)
    |> validate_required([:user_id])
    |> validate_inclusion(:default_view, @valid_views)
    |> validate_inclusion(:week_start_day, @valid_week_starts)
    |> validate_inclusion(:time_format, @valid_time_formats)
    |> validate_inclusion(:density, @valid_densities)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:bookable_meeting_type_id)
    |> foreign_key_constraint(:active_calendar_set_id)
  end
end
