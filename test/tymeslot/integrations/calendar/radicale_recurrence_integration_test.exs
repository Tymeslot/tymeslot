defmodule Tymeslot.Integrations.Calendar.RadicaleRecurrenceIntegrationTest do
  @moduledoc """
  Live proof that a CalDAV target can hold a recurring placeholder *with its
  cancellations*, which is the evidence `Capability.supports?/2` requires before
  `:recurrence` may be true for the family.

  The question this file answers is not "does the server accept an RRULE" —
  everything accepts an RRULE. It is whether the exception lines that travel
  beside the rule survive the write, because those are what stop a cancelled
  occurrence from blocking a slot on the target forever. A series mirrored with
  its rule and without its exceptions is worse than no mirror at all: it is
  wrong in a way nothing reports and nothing retries, since the write returns
  201.

  So the assertions run against what the **server** holds and expands, not
  against the document Tymeslot built. Before the fix these tests failed here:
  the payload carried the lines, `build_simple_event/2` dropped them, and the
  stored VEVENT came back with the rule alone.

  ## Running it

  Radicale in Docker on port 8800, seeded with a `testuser` collection:

      docker run -d --name radicale-test -p 8800:5232 ...

  Excluded from the default run and from CI (see
  `.github/workflows/excluded-suites.yml`) — no seeded CalDAV image is
  published for the workflow to pull. The hermetic tests in
  `ical_builder_exception_lines_test.exs` and
  `engine_caldav_series_target_test.exs` are what protect this behaviour on
  every ordinary run; this file is what proved it true once against a real
  server.

  ## One implementation, not a family

  Radicale is a single CalDAV server. It round-trips these properties verbatim
  and expands them correctly, which is what the RFC requires, but Nextcloud,
  Fastmail and iCloud are not exercised here.
  """
  use ExUnit.Case, async: false
  @moduletag :calendar_integration
  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload

  @base_url "http://localhost:8800"
  @username "testuser"
  @password "testpass123"
  @calendar_path "/testuser/default/"

  @client %{
    base_url: @base_url,
    username: @username,
    password: @password,
    calendar_paths: [@calendar_path],
    verify_ssl: false,
    provider: :radicale
  }

  # The same opt-out the Baikal integration test uses: the discovery SSRF guard
  # blocks localhost by default, and this in-process test is trusted.
  @local_opts [ip_address: "127.0.0.1", allow_private_ips: true]

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, nil)
    :ok
  end

  # A weekly series at 12:00 Europe/Tallinn, which is 09:00Z on these dates.
  # DTSTART and the EXDATE therefore name the *same instant* in two notations,
  # which is what RFC 5545 §3.8.5.1 requires for the exclusion to match: an
  # EXDATE is matched against the instants DTSTART generates, not against a
  # wall-clock read in some other zone. The two agree in production for a
  # structural reason — `RecurringSeries` reads the rule, the exception lines
  # and DTSTART off the one master event — and a test that let them disagree
  # would be asserting on a series the engine never builds.
  defp recurring_payload(uid, exception_lines) do
    source = %{
      uid: "source-#{uid}",
      summary: "Weekly standup",
      all_day: false,
      start_at: ~U[2026-09-01 09:00:00Z],
      end_at: ~U[2026-09-01 09:30:00Z],
      start_date: nil,
      end_date: nil,
      timezone: "Europe/Tallinn",
      visibility: :public
    }

    link = %CalendarSyncLinkSchema{privacy_tier: "busy_only", target_calendar_id: nil}

    MirrorPayload.build(source, uid, link,
      recurrence_rule: "FREQ=WEEKLY;COUNT=5",
      recurrence_exception_lines: exception_lines
    )
  end

  defp unique_uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The stored document, read straight back off the server rather than through
  # any parser of ours — the point is what Radicale holds, and a parser could
  # hide a property the server never received.
  defp stored_ical(uid) do
    {:ok, response} =
      Req.get("#{@base_url}#{@calendar_path}#{uid}.ics",
        auth: {:basic, "#{@username}:#{@password}"}
      )

    assert response.status == 200
    response.body
  end

  # The server's own expansion of the series, via a CalDAV `calendar-query`
  # REPORT with `<C:expand>`. This is the assertion that matters: storing the
  # EXDATE is not the feature, dropping the occurrence is.
  defp expanded_starts(uid) do
    body = """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop><C:calendar-data>
        <C:expand start="20260901T000000Z" end="20261015T000000Z"/>
      </C:calendar-data></D:prop>
      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:time-range start="20260901T000000Z" end="20261015T000000Z"/>
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>
    </C:calendar-query>
    """

    {:ok, response} =
      Req.request(
        method: "REPORT",
        url: "#{@base_url}#{@calendar_path}",
        auth: {:basic, "#{@username}:#{@password}"},
        headers: [{"depth", "1"}, {"content-type", "application/xml"}],
        body: body
      )

    assert response.status in [207, 200]

    response.body
    |> unescape_xml()
    |> then(&Regex.scan(~r/BEGIN:VEVENT.*?END:VEVENT/s, &1))
    |> Enum.map(&hd/1)
    |> Enum.filter(&String.contains?(&1, "UID:#{uid}"))
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/DTSTART[^:\r\n]*:(\S+)/, block) do
        [_full, start] -> [String.trim(start)]
        nil -> []
      end
    end)
    |> Enum.sort()
  end

  defp unescape_xml(xml) do
    xml
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  describe "a recurring mirror placeholder on a live CalDAV target" do
    test "the RRULE and the EXDATE both reach the server and are stored verbatim" do
      uid = unique_uid("tymeslot-series")

      payload = recurring_payload(uid, ["EXDATE;TZID=Europe/Tallinn:20260915T120000"])

      assert {:ok, ^uid} = CaldavCommon.create_event(@client, payload)

      stored = stored_ical(uid)

      assert stored =~ "RRULE:FREQ=WEEKLY;COUNT=5"

      assert stored =~ "EXDATE;TZID=Europe/Tallinn:20260915T120000",
             "the cancellation must survive the write:\n#{stored}"

      on_exit(fn -> CaldavCommon.delete_event(@client, uid) end)
    end

    test "the server drops the cancelled occurrence from its own expansion" do
      uid = unique_uid("tymeslot-excluded")

      payload = recurring_payload(uid, ["EXDATE;TZID=Europe/Tallinn:20260915T120000"])
      assert {:ok, ^uid} = CaldavCommon.create_event(@client, payload)
      on_exit(fn -> CaldavCommon.delete_event(@client, uid) end)

      starts = expanded_starts(uid)

      # A green check over an empty set is not a pass: a REPORT that matched
      # nothing would satisfy every `refute` below.
      assert length(starts) == 4,
             "expected the 5-occurrence series minus one cancellation, got #{inspect(starts)}"

      refute "20260915T090000Z" in starts,
             "the cancelled occurrence still blocks its slot: #{inspect(starts)}"

      assert "20260908T090000Z" in starts
      assert "20260922T090000Z" in starts
    end

    test "an EXDATE/RDATE pair moves an occurrence rather than only cancelling it" do
      uid = unique_uid("tymeslot-moved")

      # The shape `MoveCorrection.lines_for/2` produces for a moved occurrence:
      # both halves, in the series' own timezone.
      payload =
        recurring_payload(uid, [
          "EXDATE;TZID=Europe/Tallinn:20260915T120000",
          "RDATE;TZID=Europe/Tallinn:20260916T120000"
        ])

      assert {:ok, ^uid} = CaldavCommon.create_event(@client, payload)
      on_exit(fn -> CaldavCommon.delete_event(@client, uid) end)

      stored = stored_ical(uid)
      assert stored =~ "EXDATE;TZID=Europe/Tallinn:20260915T120000"
      assert stored =~ "RDATE;TZID=Europe/Tallinn:20260916T120000"

      starts = expanded_starts(uid)

      assert length(starts) == 5,
             "four remaining occurrences plus the moved one, got #{inspect(starts)}"

      refute "20260915T090000Z" in starts, "the slot the occurrence left must be freed"
      assert "20260916T090000Z" in starts, "the slot it moved to must be blocked"
    end

    test "a series with nothing cancelled writes every occurrence" do
      uid = unique_uid("tymeslot-unbroken")

      payload = recurring_payload(uid, nil)
      assert {:ok, ^uid} = CaldavCommon.create_event(@client, payload)
      on_exit(fn -> CaldavCommon.delete_event(@client, uid) end)

      stored = stored_ical(uid)
      assert stored =~ "RRULE:FREQ=WEEKLY;COUNT=5"
      refute stored =~ "EXDATE"

      assert length(expanded_starts(uid)) == 5
    end
  end

  describe "discovery against Radicale" do
    alias Tymeslot.Integrations.Calendar.CalDAV.Discovery

    test "connects and finds the seeded calendar" do
      assert {:ok, message} = Discovery.test_connection(@client, @local_opts)
      assert byte_size(message) > 0

      assert {:ok, calendars} = CaldavCommon.discover_calendars(@client, @local_opts)
      assert calendars != []
    end
  end
end
