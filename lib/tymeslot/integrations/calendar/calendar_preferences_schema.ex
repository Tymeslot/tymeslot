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

    timestamps(type: :utc_datetime)
  end

  @valid_views ~w(week day month agenda)
  @valid_week_starts ~w(monday sunday)
  @valid_time_formats TimeFormat.formats()

  @castable_fields [
    :user_id,
    :default_view,
    :hidden_integration_ids,
    :week_start_day,
    :time_format,
    :show_week_numbers,
    :show_weekends,
    :desktop_reminders_enabled
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, @castable_fields)
    |> validate_required([:user_id])
    |> validate_inclusion(:default_view, @valid_views)
    |> validate_inclusion(:week_start_day, @valid_week_starts)
    |> validate_inclusion(:time_format, @valid_time_formats)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
