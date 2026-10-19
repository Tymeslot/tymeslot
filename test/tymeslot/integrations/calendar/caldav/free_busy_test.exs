defmodule Tymeslot.Integrations.Calendar.CalDAV.FreeBusyTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.FreeBusy

  @path "/calendars/colleague/availability/"

  defp vfreebusy(lines) do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Example//Server//EN",
        "BEGIN:VFREEBUSY",
        "DTSTART:20260810T000000Z",
        "DTEND:20260811T000000Z"
      ] ++ lines ++ ["END:VFREEBUSY", "END:VCALENDAR", ""],
      "\r\n"
    )
  end

  defp intervals(body) do
    {:ok, events} = FreeBusy.parse(body, @path)
    Enum.map(events, &{&1.start_time, &1.end_time})
  end

  describe "build_query/2" do
    test "asks for the busy time of the range, in UTC" do
      body =
        FreeBusy.build_query(
          DateTime.new!(~D[2026-08-10], ~T[02:00:00], "Europe/Berlin"),
          ~U[2026-08-11 00:00:00Z]
        )

      assert body =~ "<c:free-busy-query"
      assert body =~ ~s(<c:time-range start="20260810T000000Z" end="20260811T000000Z"/>)
    end
  end

  describe "parse/2" do
    test "reads a period given as start and end" do
      assert intervals(vfreebusy(["FREEBUSY:20260810T090000Z/20260810T100000Z"])) ==
               [{~U[2026-08-10 09:00:00Z], ~U[2026-08-10 10:00:00Z]}]
    end

    test "reads a period given as start and duration" do
      assert intervals(vfreebusy(["FREEBUSY:20260810T090000Z/PT1H30M"])) ==
               [{~U[2026-08-10 09:00:00Z], ~U[2026-08-10 10:30:00Z]}]

      assert intervals(vfreebusy(["FREEBUSY:20260810T090000Z/P1D"])) ==
               [{~U[2026-08-10 09:00:00Z], ~U[2026-08-11 09:00:00Z]}]
    end

    test "reads several periods on one line" do
      assert intervals(
               vfreebusy(["FREEBUSY:20260810T090000Z/20260810T100000Z,20260810T140000Z/PT30M"])
             ) == [
               {~U[2026-08-10 09:00:00Z], ~U[2026-08-10 10:00:00Z]},
               {~U[2026-08-10 14:00:00Z], ~U[2026-08-10 14:30:00Z]}
             ]
    end

    test "keeps every busy type and drops free time" do
      body =
        vfreebusy([
          "FREEBUSY;FBTYPE=BUSY:20260810T090000Z/PT1H",
          "FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260810T110000Z/PT1H",
          "FREEBUSY;FBTYPE=BUSY-UNAVAILABLE:20260810T130000Z/PT1H",
          "FREEBUSY;FBTYPE=FREE:20260810T150000Z/PT1H"
        ])

      assert Enum.map(intervals(body), &elem(&1, 0)) == [
               ~U[2026-08-10 09:00:00Z],
               ~U[2026-08-10 11:00:00Z],
               ~U[2026-08-10 13:00:00Z]
             ]
    end

    test "reads a line folded across two" do
      body = vfreebusy(["FREEBUSY;FBTYPE=BUSY:20260810T090000Z/20260810T1", " 00000Z"])

      assert intervals(body) == [{~U[2026-08-10 09:00:00Z], ~U[2026-08-10 10:00:00Z]}]
    end

    test "skips a period it cannot read and keeps the rest" do
      body = vfreebusy(["FREEBUSY:20260810T090000/PT1H,nonsense,20260810T110000Z/PT1H"])

      assert intervals(body) == [{~U[2026-08-10 11:00:00Z], ~U[2026-08-10 12:00:00Z]}]
    end

    test "keeps two periods that start together apart" do
      # The read dedupes events on their uid, so a short tentative period
      # must not swallow a longer one starting at the same time.
      {:ok, events} =
        FreeBusy.parse(
          vfreebusy([
            "FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260810T140000Z/PT30M",
            "FREEBUSY;FBTYPE=BUSY-UNAVAILABLE:20260810T140000Z/PT2H"
          ]),
          @path
        )

      assert events |> Enum.map(& &1.uid) |> Enum.uniq() |> length() == 2

      assert Enum.map(events, & &1.end_time) == [
               ~U[2026-08-10 14:30:00Z],
               ~U[2026-08-10 16:00:00Z]
             ]
    end

    test "refuses a body that holds no free/busy answer, rather than reading it as free" do
      for body <- [
            ~s(<D:multistatus xmlns:D="DAV:"></D:multistatus>),
            "<html><body>502 Bad Gateway</body></html>",
            ""
          ] do
        assert FreeBusy.parse(body, @path) == {:error, :not_free_busy}
      end
    end

    test "reads a free/busy answer with no busy periods as free" do
      assert FreeBusy.parse(vfreebusy([]), @path) == {:ok, []}
    end

    test "answers busy periods as opaque, confirmed events of that calendar" do
      {:ok, [event]} = FreeBusy.parse(vfreebusy(["FREEBUSY:20260810T090000Z/PT1H"]), @path)

      assert %{href: @path, transparency: "opaque", status: "CONFIRMED", summary: nil} = event
      assert event.uid =~ @path
    end
  end
end
