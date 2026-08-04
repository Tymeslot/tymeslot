defmodule Tymeslot.Integrations.Calendar.Ics.FeedTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Ics.Feed

  # Exercises the real HTTPClient → Req → Req.Test path, so redirect handling
  # and status classification are covered as they actually run rather than
  # through a stubbed client module. SSRF guarding itself is covered by
  # FeedSsrfTest, alongside this module.

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Example Corp//Publisher//EN
  BEGIN:VEVENT
  UID:event-one@example.com
  DTSTART:20260810T090000Z
  DTEND:20260810T100000Z
  SUMMARY:Sprint planning
  END:VEVENT
  BEGIN:VEVENT
  UID:event-two@example.com
  DTSTART:20260811T140000Z
  DTEND:20260811T150000Z
  SUMMARY:Retro
  END:VEVENT
  END:VCALENDAR
  """

  defp stub_ics(body, status \\ 200) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/calendar")
      |> Conn.send_resp(status, body)
    end)
  end

  describe "fetch_events/2" do
    test "parses every VEVENT in the feed" do
      stub_ics(@ics)

      assert {:ok, events} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
      assert length(events) == 2
      assert Enum.map(events, & &1[:summary]) == ["Sprint planning", "Retro"]
    end

    test "treats 401 as unauthorised so the worker can stop retrying" do
      stub_ics("", 401)

      assert {:error, :unauthorised} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "treats 403 as unauthorised" do
      stub_ics("", 403)

      assert {:error, :unauthorised} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "reports a missing feed separately from an unauthorised one" do
      stub_ics("", 404)

      assert {:error, :not_found} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "reports any other failing status with its code" do
      stub_ics("", 503)

      assert {:error, {:http_status, 503}} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "rejects a body that is not iCalendar" do
      stub_ics("<html><body>Sign in to continue</body></html>")

      assert {:error, :invalid_ics} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "rejects a feed larger than the size cap" do
      oversized = String.duplicate("x", Feed.max_feed_bytes() + 1)
      stub_ics(oversized)

      assert {:error, :too_large} = Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "follows a redirect to the real feed location" do
      stub_sequential(
        fn conn ->
          conn
          |> Conn.put_resp_header("location", "https://cdn.example.com/real.ics")
          |> Conn.send_resp(302, "")
        end,
        fn conn ->
          assert conn.host == "cdn.example.com"
          Conn.send_resp(conn, 200, @ics)
        end
      )

      assert {:ok, [_first, _second]} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "gives up rather than following a redirect loop" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://feeds.example.com/calendar.ics")
        |> Conn.send_resp(302, "")
      end)

      assert {:error, :too_many_redirects} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end
  end

  describe "normalise_url/1" do
    test "rewrites the webcal scheme vendors hand out" do
      assert Feed.normalise_url("webcal://feeds.example.com/calendar.ics") ==
               "https://feeds.example.com/calendar.ics"
    end

    test "leaves an https URL untouched" do
      assert Feed.normalise_url("https://feeds.example.com/calendar.ics") ==
               "https://feeds.example.com/calendar.ics"
    end

    test "rewrites the webcal scheme regardless of casing" do
      assert Feed.normalise_url("WebCal://feeds.example.com/calendar.ics") ==
               "https://feeds.example.com/calendar.ics"

      assert Feed.normalise_url("WEBCAL://feeds.example.com/calendar.ics") ==
               "https://feeds.example.com/calendar.ics"
    end

    test "trims surrounding whitespace before rewriting the scheme" do
      assert Feed.normalise_url("  webcal://feeds.example.com/calendar.ics  ") ==
               "https://feeds.example.com/calendar.ics"
    end

    test "trims surrounding whitespace on non-webcal URLs" do
      assert Feed.normalise_url("  https://feeds.example.com/calendar.ics  ") ==
               "https://feeds.example.com/calendar.ics"
    end
  end

  describe "error_message/1" do
    @error_cases [
      {:unauthorised, "revoked"},
      {:not_found, "404"},
      {:invalid_ics, ".ics"},
      {:too_large, "too large"},
      {:too_many_redirects, "redirected too many"},
      {:missing_url, "Enter"},
      {{:blocked, "URL resolves to a private or local network address"}, "blocked"},
      {{:http_status, 503}, "503"},
      {:some_unmapped_reason, "Could not reach"}
    ]

    for {error, expected_fragment} <- @error_cases do
      test "#{inspect(error)} returns a message mentioning #{inspect(expected_fragment)}" do
        message = Feed.error_message(unquote(Macro.escape(error)))

        assert message != ""
        assert message =~ unquote(expected_fragment)
      end
    end

    test "every declared error value gets a distinct message" do
      messages = Enum.map(@error_cases, fn {error, _fragment} -> Feed.error_message(error) end)

      assert Enum.uniq(messages) == messages
    end
  end
end
