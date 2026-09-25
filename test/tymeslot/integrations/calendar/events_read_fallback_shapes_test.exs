defmodule Tymeslot.Integrations.Calendar.EventsReadFallbackShapesTest do
  @moduledoc """
  The wide-range fallback in `EventsRead` filters whatever shape the provider
  hands back, and the two shapes it gets wrong are the ones no stub in
  `EventsReadTest` produces: all-day events, which arrive as bare `Date`
  structs, and the raw string-keyed API maps Google and Outlook return before
  normalisation. Both reach the filter only after the primary ranged fetch has
  failed, which is why they went unnoticed in production too.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.EventsRead

  @base_time ~U[2024-01-01 12:00:00Z]

  # Both stubs fail the narrow ranged fetch and answer only the wide-range
  # retry, so it is the fallback filter that every test below exercises.
  defmodule WideRange do
    @wide_range_days 300

    @spec asked_for?(keyword()) :: boolean()
    def asked_for?(opts) do
      start_time = opts[:start_time]
      end_time = opts[:end_time]

      start_time != nil and end_time != nil and
        DateTime.diff(end_time, start_time, :day) >= @wide_range_days
    end
  end

  # All-day events reach this path as bare `%Date{}` values: the iCal parser
  # emits them for DATE-form DTSTART/DTEND, and CalDAV is the provider that
  # actually produces them in production.
  defmodule AllDayCalDavProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())} | {:error, :forced_failure}
    def list_events(_client, opts) do
      if WideRange.asked_for?(opts) do
        {:ok,
         [
           %{uid: "all-day-in-range", start_time: ~D[2024-01-01], end_time: ~D[2024-01-02]},
           %{uid: "all-day-out-of-range", start_time: ~D[2023-06-01], end_time: ~D[2023-06-02]}
         ]}
      else
        {:error, :forced_failure}
      end
    end
  end

  # Mirrors Google/Outlook: `list_events/2` answers with the raw string-keyed
  # API maps and the provider exposes `convert_events/1`, so the read path has
  # to normalise before it can read `:start_time` off an event at all.
  defmodule RawApiShapeProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())} | {:error, :forced_failure}
    def list_events(_client, opts) do
      if WideRange.asked_for?(opts) do
        {:ok,
         [
           %{"id" => "busy", "start" => "2024-01-01T12:00:00Z", "end" => "2024-01-01T13:00:00Z"},
           %{
             "id" => "long-past",
             "start" => "2023-01-01T12:00:00Z",
             "end" => "2023-01-01T13:00:00Z"
           }
         ]}
      else
        {:error, :forced_failure}
      end
    end

    @spec convert_events(list(map())) :: list(map())
    def convert_events(raw_events) do
      Enum.map(raw_events, fn raw ->
        %{uid: raw["id"], start_time: parse(raw["start"]), end_time: parse(raw["end"])}
      end)
    end

    defp parse(value) do
      {:ok, datetime, _offset} = DateTime.from_iso8601(value)
      datetime
    end
  end

  describe "fetch_events_with_fallback/3 over all-day events" do
    test "keeps an all-day event that overlaps the range and drops one that does not" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: AllDayCalDavProvider,
        client: %{calendar_path: "/cal/all-day"}
      }

      start_dt = DateTime.add(@base_time, -86_400, :second)
      end_dt = DateTime.add(@base_time, 86_400, :second)

      assert {:ok, events, "/cal/all-day"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      assert Enum.map(events, & &1.uid) == ["all-day-in-range"]
    end

    test "leaves the all-day event's Date values untouched" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: AllDayCalDavProvider,
        client: %{calendar_path: "/cal/all-day"}
      }

      start_dt = DateTime.add(@base_time, -86_400, :second)
      end_dt = DateTime.add(@base_time, 86_400, :second)

      assert {:ok, [event], _path} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      # `Availability.Events` matches on `%Date{}` downstream to anchor the
      # event to the owner's local midnight, so coercing it to a DateTime for
      # the range check must not leak into the event that is returned.
      assert event.start_time == ~D[2024-01-01]
      assert event.end_time == ~D[2024-01-02]
    end
  end

  describe "fetch_events_with_fallback/3 over un-normalised provider events" do
    test "normalises raw API events before filtering them" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: RawApiShapeProvider,
        client: %{calendar_path: "/cal/raw"}
      }

      start_dt = DateTime.add(@base_time, -3600, :second)
      end_dt = DateTime.add(@base_time, 3600, :second)

      assert {:ok, events, "/cal/raw"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      # Filtering the raw maps drops every event and reports `{:ok, []}`, which
      # the availability path reads as an empty calendar and books straight
      # over this conflict.
      assert Enum.map(events, & &1.uid) == ["busy"]
    end
  end
end
