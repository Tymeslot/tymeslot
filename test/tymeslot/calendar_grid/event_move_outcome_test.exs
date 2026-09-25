defmodule Tymeslot.CalendarGrid.EventMoveOutcomeTest do
  @moduledoc """
  What `CalendarGrid.move_event/3` reports and caches once the destination has
  accepted the event: the uid the moved row is cached under on providers that
  mint their own ids, and a failure after the create, which must never read as
  a move that did not happen.

  Provider writes are stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`); the Google and Outlook answers go through each
  provider's own conversion, as a real create's would.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Ecto.Query
  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser, as: GoogleEventNormaliser
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/src/"])

    destination =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/dest/"])

    %{user: user, source: source, destination: destination}
  end

  describe "move_event/3 to a provider that mints its own ids" do
    test "a Google event is cached under the iCalUID sync keys it by, and a sync adds no second row",
         %{user: user, source: source} do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(source)

      # What Google answers an insert with: its own event id and an iCalUID
      # that is not derived from it.
      response = fn payload ->
        %{
          "id" => "gevent0001",
          "iCalUID" => "4f1c2e0a9b@google.com",
          "etag" => "\"3391\"",
          "status" => "confirmed",
          "summary" => payload.summary,
          "start" => %{"dateTime" => "2026-06-01T09:00:00Z"},
          "end" => %{"dateTime" => "2026-06-01T10:00:00Z"}
        }
      end

      expect_create(fn payload ->
        {:ok,
         payload
         |> response.()
         |> GoogleProvider.convert_event()
         |> CreatedEvent.from_provider_event()}
      end)

      expect_delete(:ok)

      assert {:ok, %{uid: "4f1c2e0a9b@google.com"}} = move(user, event, google, "primary")
      assert [{:create, payload, _context}, _delete] = provider_calls()

      assert {:ok, row} =
               ProviderCalendarEventQueries.get_by_uid(google.id, "4f1c2e0a9b@google.com")

      assert row.provider_event_id == "gevent0001"

      context = %{
        calendar_integration_id: google.id,
        provider_calendar_id: "primary",
        synced_at: DateTime.utc_now()
      }

      {:ok, synced} = GoogleEventNormaliser.normalise_events([response.(payload)], context)
      assert {:ok, 1} = Sync.upsert_cache(google, synced)

      assert [%{uid: "4f1c2e0a9b@google.com", provider_event_id: "gevent0001"}] =
               cached_rows(google)
    end

    test "an Outlook event is cached under the iCalUId sync keys it by", %{
      user: user,
      source: source
    } do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      event = insert_event(source)

      expect_create(fn payload ->
        [converted] =
          OutlookCalendarAPI.convert_to_common_format([
            %{
              "id" => "AAMkAGI2outlook",
              "iCalUId" => "040000008200E00074C5B7101A82E008",
              "subject" => payload.summary,
              "start" => %{"dateTime" => "2026-06-01T09:00:00.0000000", "timeZone" => "UTC"},
              "end" => %{"dateTime" => "2026-06-01T10:00:00.0000000", "timeZone" => "UTC"}
            }
          ])

        {:ok, converted |> OutlookProvider.convert_event() |> CreatedEvent.from_provider_event()}
      end)

      expect_delete(:ok)

      assert {:ok, %{uid: "040000008200E00074C5B7101A82E008"}} = move(user, event, outlook)

      assert [%{uid: "040000008200E00074C5B7101A82E008", provider_event_id: "AAMkAGI2outlook"}] =
               cached_rows(outlook)
    end
  end

  describe "move_event/3 when something fails after the destination accepted the event" do
    test "a failed cache write reports the event as copied, not as left where it was", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)

      # A tag PostgreSQL refuses to store, so the destination row cannot be
      # written although the create succeeded.
      expect_create(fn payload -> {:ok, CreatedEvent.new(payload.uid, etag: "bad\x00tag")} end)
      refute_delete()

      assert {:ok, %{uid: uid, integration_id: integration_id, source: :unknown}} =
               move(user, event, destination)

      assert [{:create, payload, _context}] = provider_calls()
      assert {uid, integration_id} == {payload.uid, destination.id}
    end

    test "a raise in the source delete reports the event as copied", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)
      expect_create(&created/1)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        raise "connection closed"
      end)

      assert {:ok, %{uid: uid, source: :unknown}} = move(user, event, destination)
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(destination.id, uid)
    end

    test "a raise before the create answered still escapes as a failed move", %{
      user: user,
      source: source,
      destination: destination
    } do
      event = insert_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _payload, _context ->
        raise "connection closed"
      end)

      refute_delete()

      assert_raise RuntimeError, "connection closed", fn -> move(user, event, destination) end
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
    end
  end

  defp insert_event(integration) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/src/",
      provider_event_id: "/src/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    )
  end

  defp expect_create(result_fun) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn payload, context ->
      send(test_pid, {:provider_call, {:create, payload, context}})
      result_fun.(payload)
    end)
  end

  defp created(payload), do: {:ok, CreatedEvent.new(payload.uid)}

  defp expect_delete(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
      send(test_pid, {:provider_call, {:delete, uid, context, opts}})
      result
    end)
  end

  defp refute_delete,
    do: expect(Tymeslot.CalendarMock, :delete_event, 0, fn _uid, _context, _opts -> :ok end)

  defp provider_calls(calls \\ []) do
    receive do
      {:provider_call, call} -> provider_calls([call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp cached_rows(integration) do
    Repo.all(
      from(row in ProviderCalendarEventSchema,
        where: row.calendar_integration_id == ^integration.id
      )
    )
  end

  defp move(user, event, integration, calendar_id \\ nil) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: calendar_id})
  end
end
