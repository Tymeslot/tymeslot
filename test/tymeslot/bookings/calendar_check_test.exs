defmodule Tymeslot.Bookings.CalendarCheckTest do
  @moduledoc """
  The submit-time calendar re-read asks providers for whole UTC days, so the
  days it fetches must reach as far as the buffers do: back by the
  before-buffer from the slot's start, forward by the after-buffer from its
  end. A range widened on the wrong side would miss a clash sitting just past
  midnight and wave the booking through.

  On top of that the range is padded by one day each side, so an all-day event
  on the host's local day is returned whichever UTC day that falls in; the
  expected ranges below include that padding.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :calendar

  import Mox

  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.CalendarMock

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      send(test_pid, {:fetched, start_date, end_date})
      {:ok, []}
    end)

    %{user: insert(:user)}
  end

  test "a before-buffer crossing midnight reaches back into the previous day", %{user: user} do
    assert :ok =
             CalendarCheck.probe(slot(user, ~U[2026-11-10 00:10:00Z]), %{
               buffer_before_minutes: 15,
               buffer_after_minutes: 0
             })

    assert_received {:fetched, ~D[2026-11-08], ~D[2026-11-11]}
  end

  test "an after-buffer of the same size at the same time does not", %{user: user} do
    assert :ok =
             CalendarCheck.probe(slot(user, ~U[2026-11-10 00:10:00Z]), %{
               buffer_before_minutes: 0,
               buffer_after_minutes: 15
             })

    assert_received {:fetched, ~D[2026-11-09], ~D[2026-11-11]}
  end

  test "an after-buffer crossing midnight reaches forward into the next day", %{user: user} do
    assert :ok =
             CalendarCheck.probe(slot(user, ~U[2026-11-10 23:20:00Z]), %{
               buffer_before_minutes: 0,
               buffer_after_minutes: 15
             })

    assert_received {:fetched, ~D[2026-11-09], ~D[2026-11-12]}
  end

  describe "probe_many/3" do
    @buffers %{buffer_before_minutes: 15, buffer_after_minutes: 15, owner_timezone: "Etc/UTC"}

    test "reports the busy slots from one fetch over the whole range", %{user: user} do
      test_pid = self()

      # One event overlapping the second slot, one ending inside the fourth's
      # before-buffer: the buffers count exactly as they do for `probe/3`.
      events = [
        %{uid: "a", start_time: ~U[2026-11-17 10:10:00Z], end_time: ~U[2026-11-17 10:20:00Z]},
        %{uid: "b", start_time: ~U[2026-12-01 09:00:00Z], end_time: ~U[2026-12-01 09:50:00Z]}
      ]

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
        send(test_pid, {:fetched, start_date, end_date})
        {:ok, events}
      end)

      starts = [
        ~U[2026-11-10 10:00:00Z],
        ~U[2026-11-17 10:00:00Z],
        ~U[2026-11-24 10:00:00Z],
        ~U[2026-12-01 10:00:00Z]
      ]

      assert {:ok, %{busy: busy}} =
               CalendarCheck.probe_many(Enum.map(starts, &slot(user, &1)), @buffers)

      assert busy == MapSet.new([~U[2026-11-17 10:00:00Z], ~U[2026-12-01 10:00:00Z]])

      # Exactly one fetch, over the whole buffered range, before anything else
      # in this test reads the calendar.
      assert_received {:fetched, ~D[2026-11-09], ~D[2026-12-02]}
      refute_received {:fetched, _start_date, _end_date}

      # Each slot is judged as `probe/3` judges it alone.
      for start <- starts do
        expected = if MapSet.member?(busy, start), do: {:error, :slot_unavailable}, else: :ok
        assert CalendarCheck.probe(slot(user, start), @buffers) == expected
      end
    end

    test "an unreadable calendar is an error", %{user: user} do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :some_calendars_unavailable}
      end)

      slots = [slot(user, ~U[2026-11-10 10:00:00Z]), slot(user, ~U[2026-11-17 10:00:00Z])]

      assert {:error, :some_calendars_unavailable} = CalendarCheck.probe_many(slots, @buffers)
      assert {:error, :availability_unverifiable} = CalendarCheck.enforce_many(slots, @buffers)
    end

    test "a transport failure is waved through by enforce_many/3", %{user: user} do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :network_error}
      end)

      slots = [slot(user, ~U[2026-11-10 10:00:00Z]), slot(user, ~U[2026-11-17 10:00:00Z])]

      assert {:error, :network_error} = CalendarCheck.probe_many(slots, @buffers)
      assert {:ok, %{busy: busy}} = CalendarCheck.enforce_many(slots, @buffers)
      assert MapSet.size(busy) == 0
    end

    test "no slots fetch nothing", %{user: _user} do
      assert {:ok, %{busy: busy}} = CalendarCheck.probe_many([], @buffers)
      assert MapSet.size(busy) == 0
      refute_received {:fetched, _start_date, _end_date}
    end
  end

  defp slot(user, start_datetime) do
    %{
      organizer_user_id: user.id,
      start_datetime: start_datetime,
      end_datetime: DateTime.add(start_datetime, 30, :minute)
    }
  end
end
