defmodule Tymeslot.Integrations.Calendar.EventsReadFallbackWindowTest do
  @moduledoc """
  The wide-range fallback in `EventsRead` answers a range only from a read
  that covered it. A read of its default window alone (30 days back, a year
  ahead) answered a range beyond that window as empty, which the availability
  path cannot tell from a free calendar: a booking page would offer slots
  over a busy one.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Runtime.EventsRead

  # A provider that answers honestly for the range it is asked, but fails any
  # read narrower than the fallback's, so every read below is the fallback's.
  defmodule BusyFarAhead do
    @spec busy_at() :: DateTime.t()
    def busy_at, do: DateTime.truncate(DateTime.add(DateTime.utc_now(), 500, :day), :second)

    @spec list_events(any(), keyword()) :: {:ok, [map()]} | {:error, :forced_failure}
    def list_events(_client, opts) do
      from = opts[:start_time]
      to = opts[:end_time]

      if DateTime.diff(to, from, :day) >= 300 do
        busy = %{
          uid: "busy-far-ahead",
          start_time: busy_at(),
          end_time: DateTime.add(busy_at(), 3600)
        }

        {:ok,
         Enum.filter(
           [busy],
           &(DateTime.compare(&1.start_time, to) == :lt and
               DateTime.compare(&1.end_time, from) == :gt)
         )}
      else
        {:error, :forced_failure}
      end
    end

    @spec convert_events([map()]) :: [map()]
    def convert_events(events), do: events
  end

  test "answers a range beyond the default window from a read that covered it" do
    client = %{
      provider_type: :fake,
      provider_module: BusyFarAhead,
      client: %{calendar_path: "/cal/far"}
    }

    from = DateTime.add(BusyFarAhead.busy_at(), -86_400)
    to = DateTime.add(BusyFarAhead.busy_at(), 86_400)

    assert {:ok, events, "/cal/far"} = EventsRead.fetch_events_with_fallback(client, from, to)
    assert Enum.map(events, & &1.uid) == ["busy-far-ahead"]
  end
end
