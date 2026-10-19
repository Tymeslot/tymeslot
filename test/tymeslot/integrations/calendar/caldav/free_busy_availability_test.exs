defmodule Tymeslot.Integrations.Calendar.CalDAV.FreeBusyAvailabilityTest do
  @moduledoc """
  A CalDAV calendar shared with the host as busy times only, on the booking
  page: read through the free-busy-query REPORT, since it answers the
  calendar-query every other calendar is read with 403, its busy periods
  take slots, and a refused REPORT refuses them all, as for any other
  calendar that cannot be read.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :calendar
  @moduletag :integration

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Availability.Offer

  @moduletag :capture_log

  @own "/calendars/host/personal/"
  @shared "/calendars/colleague/availability/"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :calendar_module, nil)
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

    %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")

    insert(:calendar_integration,
      user: user,
      provider: "caldav",
      base_url: "https://dav.example.com",
      is_active: true,
      calendar_paths: [@own, @shared],
      calendar_list: [
        %{id: @own, path: @own, name: "Personal", selected: true},
        %{
          id: @shared,
          path: @shared,
          name: "Colleague",
          selected: true,
          read_only: true,
          free_busy_only: true
        }
      ]
    )

    %{profile: profile, date: next_bookable_weekday()}
  end

  # The own calendar holds nothing; the shared one is busy 14:00-15:00 and
  # refuses calendar-query, as such a share does.
  defp serve(test_pid, date, shared_status \\ 200) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:report, conn.request_path, query_kind(body)})

      case {conn.request_path, query_kind(body)} do
        {@shared, :free_busy} when shared_status == 200 ->
          Conn.send_resp(conn, 200, vfreebusy(date))

        {@shared, _kind} ->
          Conn.send_resp(conn, max(shared_status, 403), "Forbidden")

        {@own, :calendar} ->
          Conn.send_resp(conn, 207, ~s(<D:multistatus xmlns:D="DAV:"></D:multistatus>))
      end
    end)
  end

  defp query_kind(body), do: if(body =~ "free-busy-query", do: :free_busy, else: :calendar)

  defp vfreebusy(date) do
    day = Date.to_iso8601(date, :basic)

    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VFREEBUSY",
        "FREEBUSY;FBTYPE=BUSY:#{day}T140000Z/PT1H",
        "END:VFREEBUSY",
        "END:VCALENDAR",
        ""
      ],
      "\r\n"
    )
  end

  defp slots(profile, date),
    do:
      Offer.slots_for_date(
        %{profile: profile, user_timezone: "Etc/UTC"},
        Date.to_iso8601(date),
        30
      )

  test "its busy periods take slots, asked for by free-busy-query", %{
    profile: profile,
    date: date
  } do
    serve(self(), date)

    assert {:ok, slots} = slots(profile, date)
    # 14:00-15:00 busy, and the buffer around it, gone; the day otherwise
    # open on either side.
    refute "2:00 PM" in slots
    refute "2:30 PM" in slots
    assert "1:00 PM" in slots
    assert "3:30 PM" in slots

    assert_received {:report, @shared, :free_busy}
    refute_received {:report, @shared, :calendar}
  end

  test "an answer that is not free/busy refuses every slot", %{profile: profile, date: date} do
    ReqTest.stub(:tymeslot_http, fn conn ->
      case conn.request_path do
        @shared -> Conn.send_resp(conn, 207, ~s(<D:multistatus xmlns:D="DAV:"></D:multistatus>))
        @own -> Conn.send_resp(conn, 207, ~s(<D:multistatus xmlns:D="DAV:"></D:multistatus>))
      end
    end)

    assert {:error, _reason} = slots(profile, date)
  end

  test "a refused REPORT refuses every slot", %{profile: profile, date: date} do
    serve(self(), date, 403)

    assert {:error, _reason} = slots(profile, date)
  end
end
