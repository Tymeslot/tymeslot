defmodule Tymeslot.Integrations.Calendar.SingleEventFetchTest do
  @moduledoc """
  Fetching one event straight from its calendar provider, bypassing the sync
  cache. What matters is the line between "the provider says the event does
  not exist", which callers may act on destructively, and "the provider could
  not be asked", which they must not: only a 404 or 410 is `:not_found`.
  """

  # Not async: the calendar circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CalDAVAccountStub

  setup :verify_on_exit!

  describe "Google's events.get" do
    setup do
      %{integration: oauth_integration("google")}
    end

    test "returns the event", %{integration: integration} do
      expect(HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        send(self(), {:url, url})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "abc123def"})}}
      end)

      assert {:ok, %{"id" => "abc123def"}} = GoogleAPI.get_event(integration, "work", "abc123def")
      assert_received {:url, url}
      assert String.contains?(url, "/calendars/work/events/abc123def")
    end

    test "reports a missing event as not found", %{integration: integration} do
      expect_status(404)

      assert {:error, :not_found, _message} =
               GoogleAPI.get_event(integration, "work", "abc123def")
    end

    test "reports a purged event as gone", %{integration: integration} do
      expect_status(410)

      assert {:error, :gone, _message} = GoogleAPI.get_event(integration, "work", "abc123def")
    end

    test "reports a server failure as something other than not found", %{
      integration: integration
    } do
      expect_status(500)

      assert {:error, :network_error, _message} =
               GoogleAPI.get_event(integration, "work", "abc123def")
    end
  end

  describe "Outlook's GET event" do
    setup do
      %{integration: oauth_integration("outlook")}
    end

    test "returns the event", %{integration: integration} do
      expect(HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        send(self(), {:url, url})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "AAMk1"})}}
      end)

      assert {:ok, %{"id" => "AAMk1"}} = OutlookAPI.get_event(integration, "AAMk1")
      assert_received {:url, url}
      assert String.starts_with?(url, "https://graph.microsoft.com/v1.0/me/events/AAMk1")
    end

    test "reports a missing event as not found", %{integration: integration} do
      expect_status(404)

      assert {:error, :not_found, _message} = OutlookAPI.get_event(integration, "AAMk1")
    end
  end

  describe "Operations.fetch_event/2 on a CalDAV integration" do
    setup do
      user = insert(:user)
      host = "dav-#{System.unique_integer([:positive])}.example.com"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://#{host}",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("s3cret"),
          calendar_paths: ["/calendars/alice/home/", "/calendars/alice/work/"]
        )

      # The account also holds a calendar Tymeslot does not read, where the
      # search for a moved event reaches.
      account = %{
        calendars: [
          "/calendars/alice/home/",
          "/calendars/alice/work/",
          "/calendars/alice/private/"
        ],
        notify: self()
      }

      answer_account(account)

      %{integration: integration, user: user, base: "https://#{host}", account: account}
    end

    # The event may live in any calendar the integration reaches.
    test "finds an event in a calendar other than the first", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-1.ics" => {404, ""},
        "/calendars/alice/work/grid-1.ics" => {200, ical("grid-1")}
      })

      assert {:ok, [%{uid: "grid-1", start_at: ~U[2026-10-05 09:00:00Z]}]} =
               Operations.fetch_event(%{uid: "grid-1"}, {ctx.integration.id, ctx.user.id})
    end

    test "is not found only when no calendar of the account has it", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-2.ics" => {404, ""},
        "/calendars/alice/work/grid-2.ics" => {410, ""}
      })

      # A UID the server's substring match also finds is another event.
      answer_account(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/private/" => [{"/calendars/alice/private/x.ics", ical("grid-2-copy")}]
        })
      )

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-2"}, {ctx.integration.id, ctx.user.id})

      for path <- ctx.account.calendars, do: assert_received({:dav_report, ^path, "grid-2"})
    end

    # A client that moves an event between calendars need not keep the name of
    # its resource, and the event's href names the calendar it left.
    test "finds an event moved to a calendar the integration does not read", ctx do
      answer_gets(ctx, %{"/calendars/alice/work/moved.ics" => {404, ""}})

      answer_account(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/private/" => [
            {"/calendars/alice/private/D1F0-renamed.ics", ical("grid-7")}
          ]
        })
      )

      assert {:ok, [%{uid: "grid-7", provider_calendar_id: "/calendars/alice/private/"}]} =
               Operations.fetch_event(
                 %{uid: "grid-7", provider_event_id: "/calendars/alice/work/moved.ics"},
                 {ctx.integration.id, ctx.user.id}
               )
    end

    test "is not not-found when the account's calendars could not be listed", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-8.ics" => {404, ""},
        "/calendars/alice/work/grid-8.ics" => {404, ""}
      })

      answer_account(Map.put(ctx.account, :failing, %{discovery: 500}))

      assert {:error, reason} =
               Operations.fetch_event(%{uid: "grid-8"}, {ctx.integration.id, ctx.user.id})

      refute reason == :not_found
    end

    test "is not not-found when a calendar of the account could not be searched", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-9.ics" => {404, ""},
        "/calendars/alice/work/grid-9.ics" => {404, ""}
      })

      answer_account(Map.put(ctx.account, :failing, %{"/calendars/alice/private/" => 500}))

      assert {:error, reason} =
               Operations.fetch_event(%{uid: "grid-9"}, {ctx.integration.id, ctx.user.id})

      refute reason == :not_found
    end

    # A colleague's calendar shared read-only cannot hold the moved event, and
    # its 403 would otherwise leave the event's absence unproven for ever.
    test "does not search a calendar the account can only read", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-10.ics" => {404, ""},
        "/calendars/alice/work/grid-10.ics" => {404, ""}
      })

      shared = "/calendars/bob/team/"

      answer_account(
        Map.merge(ctx.account, %{
          calendars: ctx.account.calendars ++ [shared],
          read_only: [shared],
          failing: %{shared => 403}
        })
      )

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-10"}, {ctx.integration.id, ctx.user.id})

      assert_received {:dav_report, "/calendars/alice/private/", "grid-10"}
      refute_received {:dav_report, ^shared, _uid}
    end

    # A colleague's calendar the organiser selected to see their availability
    # cannot hold the organiser's event, and its refusal would otherwise
    # leave the event's absence unproven for ever.
    test "does not ask a selected calendar the account can only read", ctx do
      shared = "/calendars/bob/team/"

      integration =
        insert(:calendar_integration,
          user: ctx.user,
          provider: "caldav",
          base_url: ctx.base,
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("s3cret"),
          calendar_paths: ["/calendars/alice/home/"],
          default_booking_calendar_id: "/calendars/alice/home/",
          calendar_list: [
            %CalendarEntry{
              id: "/calendars/alice/home/",
              path: "/calendars/alice/home/",
              selected: true
            },
            %CalendarEntry{id: shared, path: shared, selected: true, read_only: true}
          ]
        )

      answer_gets(ctx, %{
        "/calendars/alice/home/grid-14.ics" => {404, ""},
        "/calendars/bob/team/grid-14.ics" => {403, "Forbidden"}
      })

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-14"}, {integration.id, ctx.user.id})
    end

    # The organiser's own resource, cancelled in a calendar client rather than
    # deleted, holds no live event.
    test "does not count the event's own resource as found when it is cancelled", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-15.ics" => {404, ""},
        "/calendars/alice/work/grid-15.ics" => {200, ical("grid-15", "STATUS:CANCELLED")}
      })

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-15"}, {ctx.integration.id, ctx.user.id})
    end

    # What an attendee's calendar keeps of a cancelled invitation is not the
    # organiser's event.
    test "does not count a cancelled copy of the event as found", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-11.ics" => {404, ""},
        "/calendars/alice/work/grid-11.ics" => {404, ""}
      })

      answer_account(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/private/" => [
            {"/calendars/alice/private/invite.ics", ical("grid-11", "STATUS:CANCELLED")}
          ]
        })
      )

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-11"}, {ctx.integration.id, ctx.user.id})
    end

    test "finds the live event past a cancelled copy in an earlier calendar", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-12.ics" => {404, ""},
        "/calendars/alice/work/grid-12.ics" => {404, ""}
      })

      answer_account(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/home/" => [
            {"/calendars/alice/home/invite.ics", ical("grid-12", "STATUS:CANCELLED")}
          ],
          "/calendars/alice/private/" => [
            {"/calendars/alice/private/moved.ics", ical("grid-12", "STATUS:CONFIRMED")}
          ]
        })
      )

      assert {:ok, [%{uid: "grid-12", provider_calendar_id: "/calendars/alice/private/"}]} =
               Operations.fetch_event(%{uid: "grid-12"}, {ctx.integration.id, ctx.user.id})
    end

    # One cancelled occurrence leaves the rest of the series live.
    test "finds a series with one cancelled occurrence", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-13.ics" => {404, ""},
        "/calendars/alice/work/grid-13.ics" => {404, ""}
      })

      answer_account(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/private/" => [
            {"/calendars/alice/private/series.ics", series_with_cancelled_occurrence("grid-13")}
          ]
        })
      )

      assert {:ok, [_first | _rest] = events} =
               Operations.fetch_event(%{uid: "grid-13"}, {ctx.integration.id, ctx.user.id})

      assert Enum.any?(events, &(&1.status != :cancelled))
    end

    # One calendar that could not answer leaves the event's absence unproven.
    test "is not not-found when a calendar could not answer", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-3.ics" => {404, ""},
        "/calendars/alice/work/grid-3.ics" => {500, "Internal Server Error"}
      })

      assert {:error, reason} =
               Operations.fetch_event(%{uid: "grid-3"}, {ctx.integration.id, ctx.user.id})

      refute reason == :not_found
    end

    test "fetches the event's own href when it is known", ctx do
      answer_gets(ctx, %{"/dav/moved/abc.ics" => {200, ical("grid-4")}})

      assert {:ok, [%{uid: "grid-4"}]} =
               Operations.fetch_event(
                 %{uid: "grid-4", provider_event_id: "/dav/moved/abc.ics"},
                 {ctx.integration.id, ctx.user.id}
               )
    end

    test "answers for no integration the user does not own", ctx do
      stranger = insert(:user)

      assert {:error, :no_calendar_integration} =
               Operations.fetch_event(%{uid: "grid-5"}, {ctx.integration.id, stranger.id})
    end
  end

  test "reports a provider that cannot fetch one event" do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "exchange")

    assert {:error, :unsupported} =
             Operations.fetch_event(%{uid: "grid-6"}, {integration.id, user.id})
  end

  defp oauth_integration(provider),
    do:
      insert(:calendar_integration,
        user: insert(:user),
        provider: provider,
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

  defp expect_status(status) do
    expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: ""}}
    end)
  end

  defp answer_account(account) do
    stub(HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      CalDAVAccountStub.answer(account, method, url, body)
    end)
  end

  # Answers each GET by path, and fails loudly on a path no case expects.
  defp answer_gets(ctx, answers) do
    stub(HTTPClientMock, :get, fn url, _headers, _opts ->
      path = String.replace_prefix(url, ctx.base, "")
      {status, body} = Map.fetch!(answers, path)
      {:ok, %Req.Response{status: status, body: body}}
    end)
  end

  defp ical(uid, status \\ nil),
    do:
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Tymeslot//EN",
          "BEGIN:VEVENT",
          "UID:#{uid}",
          "DTSTAMP:20260901T000000Z",
          "DTSTART:20261005T090000Z",
          "DTEND:20261005T093000Z",
          "SUMMARY:Planning"
        ] ++ List.wrap(status) ++ ["END:VEVENT", "END:VCALENDAR", ""],
        "\r\n"
      )

  defp series_with_cancelled_occurrence(uid),
    do:
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Tymeslot//EN",
          "BEGIN:VEVENT",
          "UID:#{uid}",
          "DTSTAMP:20260901T000000Z",
          "DTSTART:20261005T090000Z",
          "DTEND:20261005T093000Z",
          "RRULE:FREQ=WEEKLY;COUNT=4",
          "SUMMARY:Planning",
          "END:VEVENT",
          "BEGIN:VEVENT",
          "UID:#{uid}",
          "DTSTAMP:20260901T000000Z",
          "RECURRENCE-ID:20261012T090000Z",
          "DTSTART:20261012T090000Z",
          "DTEND:20261012T093000Z",
          "STATUS:CANCELLED",
          "SUMMARY:Planning",
          "END:VEVENT",
          "END:VCALENDAR",
          ""
        ],
        "\r\n"
      )
end
