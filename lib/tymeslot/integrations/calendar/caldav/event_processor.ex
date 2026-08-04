defmodule Tymeslot.Integrations.Calendar.CalDAV.EventProcessor do
  @moduledoc """
  CalDAV iCal processing — parses raw calendar data and normalises expanded
  events into canonical `CalendarEvent` structs.

  The provider-facing entry point is `Tymeslot.Integrations.Calendar.CalDAV.Provider.normalise_events/2`,
  which delegates here. Normalisation itself lives in
  `Tymeslot.Integrations.Calendar.ICalNormaliser`, shared with subscribed ICS
  feeds, since both receive the same `ICalParser` output and differ only in
  which provider the resulting events belong to. This module additionally
  exposes `parse_ical_from_string/1` and `clean_etag/1` as iCal processing
  helpers used by sync workers.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser

  @spec normalise_events([map()], map()) :: {:ok, [CalendarEvent.t()]}
  def normalise_events(raw_events, context) do
    ICalNormaliser.normalise_events(raw_events, context, :caldav)
  end

  @doc """
  Parses a raw iCalendar string and returns the first event found.
  """
  @spec parse_ical_from_string(String.t() | term()) ::
          {:ok,
           %{
             required(:uid) => String.t(),
             required(:summary) => String.t() | nil,
             required(:description) => String.t() | nil,
             required(:location) => String.t() | nil,
             required(:organizer) => %{String.t() => String.t() | nil} | nil,
             required(:attendees) => list(%{String.t() => String.t() | nil}),
             required(:recurrence_rule) => String.t() | nil,
             required(:recurrence_id) => String.t() | nil,
             required(:exdates) => list(),
             required(:start_time) => DateTime.t() | Date.t(),
             required(:end_time) => DateTime.t() | Date.t() | nil,
             required(:transparency) => String.t() | nil
           }}
          | {:error, :no_events | :empty_data | term()}
  def parse_ical_from_string(ical_string) when is_binary(ical_string) and ical_string != "" do
    case ICalParser.parse(ical_string) do
      {:ok, [event | _rest]} -> {:ok, event}
      {:ok, []} -> {:error, :no_events}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_ical_from_string(_other), do: {:error, :empty_data}

  @doc """
  Strips surrounding whitespace and double-quotes from an etag value.
  """
  @spec clean_etag(String.t() | term()) :: String.t() | nil
  def clean_etag(etag) when is_binary(etag) do
    etag |> String.trim() |> String.trim("\"")
  end

  def clean_etag(_other), do: nil
end
