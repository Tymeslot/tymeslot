defmodule Tymeslot.Bookings.CalendarCheckTest do
  @moduledoc """
  The submit-time calendar re-read asks providers for whole UTC days, so the
  days it fetches must reach as far as the buffers do: back by the
  before-buffer from the slot's start, forward by the after-buffer from its
  end. A range widened on the wrong side would miss a clash sitting just past
  midnight and wave the booking through.
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

    assert_received {:fetched, ~D[2026-11-09], ~D[2026-11-10]}
  end

  test "an after-buffer of the same size at the same time does not", %{user: user} do
    assert :ok =
             CalendarCheck.probe(slot(user, ~U[2026-11-10 00:10:00Z]), %{
               buffer_before_minutes: 0,
               buffer_after_minutes: 15
             })

    assert_received {:fetched, ~D[2026-11-10], ~D[2026-11-10]}
  end

  test "an after-buffer crossing midnight reaches forward into the next day", %{user: user} do
    assert :ok =
             CalendarCheck.probe(slot(user, ~U[2026-11-10 23:20:00Z]), %{
               buffer_before_minutes: 0,
               buffer_after_minutes: 15
             })

    assert_received {:fetched, ~D[2026-11-10], ~D[2026-11-11]}
  end

  defp slot(user, start_datetime) do
    %{
      organizer_user_id: user.id,
      start_datetime: start_datetime,
      end_datetime: DateTime.add(start_datetime, 30, :minute)
    }
  end
end
