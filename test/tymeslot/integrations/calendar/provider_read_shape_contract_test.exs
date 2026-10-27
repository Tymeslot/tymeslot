defmodule Tymeslot.Integrations.Calendar.ProviderReadShapeContractTest do
  @moduledoc """
  The contract between every registered calendar provider and the live
  availability read: `convert_events/1` over what `list_events/2` answers
  gives events the availability path can place in time.

  `EventsRead` calls `convert_events/1` on every provider and nothing else
  converts. A provider whose events come back still in a vendor's string-keyed
  shape would have every event read without a time, and dropped from the
  conflict check: the booking page would offer slots over the host's real
  meetings. Each provider is driven through its real `list_events/2`, with only
  the network (or the event cache it reads) supplied.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox

  alias Tymeslot.Availability.Events
  alias Tymeslot.CalDAVSyncTestFixtures
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  @range [start_time: ~U[2026-08-01 00:00:00Z], end_time: ~U[2026-08-31 23:59:59Z]]

  @caldav_family [:caldav, :radicale, :nextcloud, :zimbra, :mailbox_org, :apple, :baikal]

  @ical """
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:contract-event
  DTSTAMP:20260801T090000Z
  DTSTART:20260810T090000Z
  DTEND:20260810T100000Z
  SUMMARY:Planning
  END:VEVENT
  END:VCALENDAR
  """

  # Answers with the events `convert_events/1` leaves the availability read
  # unable to place in time; `[]` is the contract held.
  defp violations(provider, answer) do
    answer
    |> provider.convert_events()
    |> Enum.reject(&match?({:ok, _interval}, Events.to_interval(&1, "Etc/UTC")))
  end

  defp list_events!(type, client) do
    assert {:ok, [_event | _rest] = answer} =
             ProviderRegistry.get_provider!(type).list_events(client, @range)

    answer
  end

  defp answer_for(type) when type in @caldav_family do
    stub(Tymeslot.HTTPClientMock, :request, fn :report, _url, _body, _headers, _opts ->
      body = CalDAVSyncTestFixtures.caldav_report_xml("/cal/contract-event.ics", @ical)
      {:ok, %Req.Response{status: 207, body: body, headers: %{}}}
    end)

    list_events!(type, %{
      base_url: "https://caldav.example.com",
      username: "user",
      password: "pass",
      calendar_paths: ["/cal/"],
      provider: type
    })
  end

  defp answer_for(:google) do
    stub(GoogleCalendarAPIMock, :list_primary_events, fn _integration, _from, _to ->
      {:ok,
       [
         %{
           "id" => "google-event",
           "summary" => "Planning",
           "start" => %{"dateTime" => "2026-08-10T09:00:00Z"},
           "end" => %{"dateTime" => "2026-08-10T10:00:00Z"}
         }
       ]}
    end)

    list_events!(:google, oauth_integration("google"))
  end

  defp answer_for(:outlook) do
    stub(OutlookCalendarAPIMock, :list_primary_events, fn _integration, _from, _to ->
      {:ok,
       [
         %{
           "id" => "outlook-event",
           "subject" => "Planning",
           "isAllDay" => false,
           "start" => %{"dateTime" => "2026-08-10T09:00:00.0000000", "timeZone" => "UTC"},
           "end" => %{"dateTime" => "2026-08-10T10:00:00.0000000", "timeZone" => "UTC"}
         }
       ]}
    end)

    list_events!(:outlook, oauth_integration("outlook"))
  end

  defp answer_for(type) when type in [:ics_url, :exchange] do
    integration = insert(:calendar_integration, provider: Atom.to_string(type))

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: Atom.to_string(type),
      provider_calendar_id: "calendar",
      uid: "cached-event",
      start_at: ~U[2026-08-10 09:00:00.000000Z],
      end_at: ~U[2026-08-10 10:00:00.000000Z],
      all_day: false
    )

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: Atom.to_string(type),
      provider_calendar_id: "calendar",
      uid: "cached-all-day",
      start_at: nil,
      end_at: nil,
      start_date: ~D[2026-08-12],
      end_date: ~D[2026-08-13],
      all_day: true
    )

    list_events!(type, %{calendar_integration_id: integration.id})
  end

  defp answer_for(type) when type in [:debug, :demo] do
    # Demo reads through Debug's store, so the loop reaches it twice.
    with {:error, {:already_started, _pid}} <- start_supervised(DebugStore), do: :ok
    DebugStore.set_pattern(:empty)

    {:ok, _created} =
      ProviderRegistry.get_provider!(:debug).create_event(%{user_id: 1}, %{
        uid: "debug-event",
        summary: "Planning",
        all_day: false,
        start_time: ~U[2026-08-10 09:00:00Z],
        end_time: ~U[2026-08-10 10:00:00Z]
      })

    list_events!(type, %{user_id: 1})
  end

  defp oauth_integration(provider) do
    insert(:calendar_integration,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      calendar_list: []
    )
  end

  test "every registered provider's events reach the availability read with their times" do
    for type <- ProviderRegistry.list_providers() do
      provider = ProviderRegistry.get_provider!(type)

      assert violations(provider, answer_for(type)) == [],
             "#{inspect(type)} answers events the availability read cannot place in time"
    end
  end

  defmodule UnconvertedProvider do
    @moduledoc false
    @spec convert_events([map()]) :: [map()]
    def convert_events(events), do: events
  end

  test "a provider answering string-keyed API maps unchanged breaks the contract" do
    answer = [
      %{
        "id" => "api-event",
        "start" => %{"dateTime" => "2026-08-10T09:00:00Z"},
        "end" => %{"dateTime" => "2026-08-10T10:00:00Z"}
      }
    ]

    assert violations(UnconvertedProvider, answer) == answer
  end
end
