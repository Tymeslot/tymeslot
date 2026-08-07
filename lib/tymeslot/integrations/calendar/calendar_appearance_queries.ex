defmodule Tymeslot.Integrations.Calendar.CalendarAppearanceQueries do
  @moduledoc """
  Data access for `calendar_appearances`: the organiser's per-calendar colour
  and visibility choices.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Repo

  @doc """
  Writes one calendar's appearance, creating the row if this is the first choice
  made about that calendar.

  `attrs` may carry `:colour`, `:hidden`, or both. Only the keys given are
  written, so setting a colour cannot quietly un-hide a calendar.
  """
  @spec upsert(integer(), String.t(), map()) ::
          {:ok, CalendarAppearanceSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert(integration_id, provider_calendar_id, attrs) do
    existing = get(integration_id, provider_calendar_id) || %CalendarAppearanceSchema{}

    existing
    |> CalendarAppearanceSchema.changeset(
      Map.merge(attrs, %{
        calendar_integration_id: integration_id,
        provider_calendar_id: provider_calendar_id
      })
    )
    |> Repo.insert_or_update()
  end

  @spec get(integer(), String.t()) :: CalendarAppearanceSchema.t() | nil
  def get(integration_id, provider_calendar_id) do
    Repo.get_by(CalendarAppearanceSchema,
      calendar_integration_id: integration_id,
      provider_calendar_id: provider_calendar_id
    )
  end

  @doc "Every stored choice for the given integrations, in one query."
  @spec list_for_integrations([integer()]) :: [CalendarAppearanceSchema.t()]
  def list_for_integrations([]), do: []

  def list_for_integrations(integration_ids) do
    CalendarAppearanceSchema
    |> where([a], a.calendar_integration_id in ^integration_ids)
    |> Repo.all()
  end
end
