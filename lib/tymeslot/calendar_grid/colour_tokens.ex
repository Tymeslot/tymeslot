defmodule Tymeslot.CalendarGrid.ColourTokens do
  @moduledoc """
  CSS colour token names for the redesigned calendar's client-drawn grid.

  The old grid paints with Tailwind classes (`bg-calendar-tomato`). The new
  grid is drawn by JavaScript, which sets `--cal-ev: var(--color-<token>)` on
  each event, so it needs the token rather than the class. The token is the
  class without its `bg-` prefix, which keeps the palette defined once, in
  `Tymeslot.Integrations.Calendar.EventColour` and `base/variables.css`.

  `"booking"` is the bookings' token: `--color-booking` points at the
  surface's own booking colour rather than a palette entry.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.Integrations.Calendar.EventColour

  @booking "booking"

  @doc "The token for each account, keyed by integration id."
  @spec for_integrations([map()]) :: %{integer() => String.t()}
  def for_integrations(integrations) do
    integrations
    |> CalendarGrid.integration_colour_classes()
    |> Map.new(fn {id, class} -> {id, token(class)} end)
  end

  @doc """
  The token for each calendar, keyed by `{integration_id, calendar_id}`.

  A calendar the organiser gave a colour keeps it. Otherwise an account's
  first synced calendar is absent, so it falls through to the account's
  colour, and every further calendar of the account takes a rotation token no
  account and no chosen calendar uses yet, so two calendars of one account
  never paint alike while the rotation lasts. Accounts are walked in id order,
  as the account rotation is, so the result does not depend on the order the
  integrations are passed in.
  """
  @spec for_calendars([map()], [map()]) :: %{{integer(), String.t()} => String.t()}
  def for_calendars(integrations, appearances) do
    chosen =
      appearances
      |> CalendarGrid.calendar_colour_classes()
      |> Map.new(fn {key, class} -> {key, token(class)} end)

    extras =
      for integration <- Enum.sort_by(integrations, & &1.id),
          {entry, index} <- Enum.with_index(CalendarDirectory.synced_entries(integration)),
          key = {integration.id, entry.id},
          index > 0 and not Map.has_key?(chosen, key),
          do: key

    taken = MapSet.new(Map.values(for_integrations(integrations)) ++ Map.values(chosen))

    extras
    |> Enum.zip(Stream.cycle(spare_tokens(taken)))
    |> Map.new()
    |> Map.merge(chosen)
  end

  # The rotation tokens nothing paints with yet, or the whole rotation once
  # every one is taken.
  defp spare_tokens(taken) do
    rotation = Enum.map(1..EventColour.rotation_size(), &token(EventColour.rotation_class(&1)))

    case Enum.reject(rotation, &MapSet.member?(taken, &1)) do
      [] -> rotation
      spare -> spare
    end
  end

  @doc """
  The token an event paints with: its own colour, then its calendar's, then
  its account's, then the neutral fallback. Bookings always get `"booking"`.
  """
  @spec for_event(map(), map(), map()) :: String.t()
  def for_event(%{kind: :booking}, _integration_tokens, _calendar_tokens), do: @booking

  def for_event(event, integration_tokens, calendar_tokens) do
    integration_id = Map.get(event, :calendar_integration_id)

    with nil <- event |> Map.get(:colour) |> EventColour.tailwind_class() |> token(),
         nil <- Map.get(calendar_tokens, {integration_id, Map.get(event, :provider_calendar_id)}),
         nil <- Map.get(integration_tokens, integration_id) do
      token(EventColour.fallback_class())
    end
  end

  @doc "The neutral token for anything without a colour of its own."
  @spec fallback() :: String.t()
  def fallback, do: token(EventColour.fallback_class())

  defp token(nil), do: nil
  defp token("bg-" <> name), do: name
end
