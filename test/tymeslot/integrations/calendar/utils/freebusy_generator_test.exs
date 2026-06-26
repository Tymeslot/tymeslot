defmodule Tymeslot.Integrations.Calendar.FreebusyGeneratorTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.FreebusyGenerator

  describe "generate/1" do
    test "wraps a VFREEBUSY component with window bounds" do
      ics =
        FreebusyGenerator.generate(
          window_start: ~U[2030-01-01 00:00:00Z],
          window_end: ~U[2030-03-02 00:00:00Z],
          intervals: []
        )

      assert ics =~ "BEGIN:VCALENDAR"
      assert ics =~ "BEGIN:VFREEBUSY"
      assert ics =~ "DTSTART:20300101T000000Z"
      assert ics =~ "DTEND:20300302T000000Z"
      assert ics =~ "END:VFREEBUSY"
      assert ics =~ "END:VCALENDAR"
    end

    test "emits one FREEBUSY;FBTYPE=BUSY period per interval" do
      ics =
        FreebusyGenerator.generate(
          window_start: ~U[2030-01-01 00:00:00Z],
          window_end: ~U[2030-01-08 00:00:00Z],
          intervals: [
            {~U[2030-01-02 09:00:00Z], ~U[2030-01-02 10:00:00Z]},
            {~U[2030-01-03 14:00:00Z], ~U[2030-01-03 15:30:00Z]}
          ]
        )

      assert ics =~ "FREEBUSY;FBTYPE=BUSY:20300102T090000Z/20300102T100000Z"
      assert ics =~ "FREEBUSY;FBTYPE=BUSY:20300103T140000Z/20300103T153000Z"
    end

    test "normalises interval datetimes to UTC" do
      {:ok, ny_start} = DateTime.new(~D[2030-01-02], ~T[09:00:00], "America/New_York")
      {:ok, ny_end} = DateTime.new(~D[2030-01-02], ~T[10:00:00], "America/New_York")

      ics =
        FreebusyGenerator.generate(
          window_start: ~U[2030-01-01 00:00:00Z],
          window_end: ~U[2030-01-08 00:00:00Z],
          intervals: [{ny_start, ny_end}]
        )

      # New York is UTC-5 in January → 09:00 local = 14:00 UTC.
      assert ics =~ "FREEBUSY;FBTYPE=BUSY:20300102T140000Z/20300102T150000Z"
    end

    test "includes an ORGANIZER when an email is supplied" do
      ics =
        FreebusyGenerator.generate(
          window_start: ~U[2030-01-01 00:00:00Z],
          window_end: ~U[2030-01-08 00:00:00Z],
          organizer_email: "host@example.com"
        )

      assert ics =~ "ORGANIZER:mailto:host@example.com"
    end
  end
end
