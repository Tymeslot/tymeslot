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
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Security.Encryption

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

      %{integration: integration, user: user, base: "https://#{host}"}
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

    test "is not found only when every calendar says so", ctx do
      answer_gets(ctx, %{
        "/calendars/alice/home/grid-2.ics" => {404, ""},
        "/calendars/alice/work/grid-2.ics" => {410, ""}
      })

      assert {:error, :not_found} =
               Operations.fetch_event(%{uid: "grid-2"}, {ctx.integration.id, ctx.user.id})
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

  # Answers each GET by path, and fails loudly on a path no case expects.
  defp answer_gets(ctx, answers) do
    stub(HTTPClientMock, :get, fn url, _headers, _opts ->
      path = String.replace_prefix(url, ctx.base, "")
      {status, body} = Map.fetch!(answers, path)
      {:ok, %Req.Response{status: status, body: body}}
    end)
  end

  defp ical(uid),
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
          "SUMMARY:Planning",
          "END:VEVENT",
          "END:VCALENDAR",
          ""
        ],
        "\r\n"
      )
end
