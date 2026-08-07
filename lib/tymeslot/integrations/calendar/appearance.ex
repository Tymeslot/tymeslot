defmodule Tymeslot.Integrations.Calendar.Appearance do
  @moduledoc """
  The organiser's per-calendar display choices: what colour a calendar's events
  are painted, and whether they appear in the dashboard grid at all.

  A focused sibling of `Tymeslot.Integrations.Calendar` rather than more surface
  on the context itself, following the split `Tymeslot.Auth` uses: the context
  owns connecting, syncing and deleting calendars, and this owns how the ones
  already connected are displayed.

  Every write takes the acting user's id and verifies the integration is theirs
  before touching a row, so an id forged in the browser reaches
  `{:error, :not_found}` rather than another organiser's calendar.
  """

  alias Tymeslot.Integrations.Calendar.CalendarAppearanceQueries
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries

  @type result ::
          {:ok, CalendarAppearanceSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
  Sets one calendar's colour, or clears it back to the integration's colour when
  `colour` is `nil`.
  """
  @spec set_colour(integer(), integer(), String.t(), String.t() | nil) :: result()
  def set_colour(user_id, integration_id, provider_calendar_id, colour) do
    with_owned_integration(user_id, integration_id, fn ->
      CalendarAppearanceQueries.upsert(integration_id, provider_calendar_id, %{colour: colour})
    end)
  end

  @doc "Shows or hides one calendar's events in the organiser's grid."
  @spec set_hidden(integer(), integer(), String.t(), boolean()) :: result()
  def set_hidden(user_id, integration_id, provider_calendar_id, hidden) do
    with_owned_integration(user_id, integration_id, fn ->
      CalendarAppearanceQueries.upsert(integration_id, provider_calendar_id, %{hidden: hidden})
    end)
  end

  @doc """
  Every per-calendar choice belonging to this user's active integrations.

  One query for the whole grid: the dashboard needs the full set on every load,
  and a lookup per calendar would scale with how many the organiser has
  connected.
  """
  @spec list_for_user(integer()) :: [CalendarAppearanceSchema.t()]
  def list_for_user(user_id) do
    user_id
    |> CalendarIntegrationQueries.list_active_for_user()
    |> Enum.map(& &1.id)
    |> CalendarAppearanceQueries.list_for_integrations()
  end

  @doc """
  The `{integration_id, provider_calendar_id}` pairs the organiser has hidden.

  A `MapSet` because the grid tests membership once per event on every render.
  """
  @spec hidden_keys([CalendarAppearanceSchema.t()]) :: MapSet.t({integer(), String.t()})
  def hidden_keys(appearances) do
    appearances
    |> Enum.filter(& &1.hidden)
    |> MapSet.new(&{&1.calendar_integration_id, &1.provider_calendar_id})
  end

  @doc """
  The stored palette key per calendar, for the swatch picker to mark one pressed.

  Distinct from `Tymeslot.CalendarGrid.calendar_colour_classes/1`, which returns
  the resolved Tailwind classes the grid paints with. The picker compares keys,
  so inverting a class back to its key would be a second copy of the palette
  mapping and a second thing to keep in step.
  """
  @spec colour_keys([CalendarAppearanceSchema.t()]) :: %{{integer(), String.t()} => String.t()}
  def colour_keys(appearances) do
    appearances
    |> Enum.filter(&chosen?/1)
    |> Map.new(&{{&1.calendar_integration_id, &1.provider_calendar_id}, &1.colour})
  end

  @doc "Whether this row carries a colour choice, as opposed to only a visibility one."
  @spec chosen?(CalendarAppearanceSchema.t()) :: boolean()
  def chosen?(%{colour: colour}), do: is_binary(colour) and colour != ""

  # `owned_by?/2` rather than `get_for_user/2`: the latter decrypts credentials
  # and can answer `:requires_reencryption`, and neither is any business of a
  # display-only change. An integration whose credentials need re-encrypting can
  # still be recoloured.
  defp with_owned_integration(user_id, integration_id, fun) do
    if CalendarIntegrationQueries.owned_by?(integration_id, user_id) do
      fun.()
    else
      {:error, :not_found}
    end
  end
end
