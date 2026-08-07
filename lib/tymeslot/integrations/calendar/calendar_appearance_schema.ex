defmodule Tymeslot.Integrations.Calendar.CalendarAppearanceSchema do
  @moduledoc """
  One organiser choice about one calendar inside one integration: the colour its
  events are painted, and whether they are drawn at all.

  Kept out of the integration's embedded `calendar_list` on purpose. Rediscovery
  rebuilds that list from the provider and carries over only `:selected`
  (`Tymeslot.Integrations.Calendar.Selection.unify_discovered_with_existing/2`),
  so a colour stored there would vanish the next time the organiser refreshed
  their calendars, silently and long after the change that caused it.

  A missing row means "inherit": the integration's own colour, and the
  integration-level visibility in `calendar_preferences.hidden_integration_ids`.
  Deleting a row therefore restores inheritance rather than leaving a calendar
  in some third state.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour

  @type t :: %__MODULE__{
          id: integer() | nil,
          calendar_integration_id: integer() | nil,
          provider_calendar_id: String.t() | nil,
          colour: String.t() | nil,
          hidden: boolean()
        }

  schema "calendar_appearances" do
    field(:provider_calendar_id, :string)
    field(:colour, :string)
    field(:hidden, :boolean, default: false)

    belongs_to(:calendar_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(appearance, attrs) do
    appearance
    |> cast(attrs, [:calendar_integration_id, :provider_calendar_id, :colour, :hidden])
    |> validate_required([:calendar_integration_id, :provider_calendar_id])
    |> validate_colour()
    |> foreign_key_constraint(:calendar_integration_id)
    |> unique_constraint([:calendar_integration_id, :provider_calendar_id],
      name: :calendar_appearances_integration_calendar_index
    )
  end

  # nil is a valid colour and means "inherit the integration's". Anything else
  # must be a palette key, so a value from outside the picker cannot reach the
  # grid and resolve to a Tailwind class that was never generated.
  defp validate_colour(changeset) do
    validate_change(changeset, :colour, fn :colour, value ->
      if is_nil(value) or EventColour.valid_key?(value) do
        []
      else
        [colour: "is not a palette colour"]
      end
    end)
  end
end
