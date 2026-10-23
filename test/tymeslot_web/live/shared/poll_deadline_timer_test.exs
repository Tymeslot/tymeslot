defmodule TymeslotWeb.Live.Shared.PollDeadlineTimerTest do
  @moduledoc """
  The timer a poll page keeps for the next voting deadline: it fires at the
  deadline, follows a moved deadline, stays away when nothing is left to
  close, and breaks a long wait into capped steps.
  """
  use ExUnit.Case, async: true

  @moduletag :polls
  @moduletag :unit

  import Tymeslot.Factory

  alias Ecto.UUID
  alias TymeslotWeb.Live.Shared.PollDeadlineTimer

  defp open_poll(deadline_at), do: build(:poll, id: UUID.generate(), deadline_at: deadline_at)

  defp in_ms(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  test "fires at the deadline with the poll's id" do
    poll = open_poll(in_ms(50))

    assert %PollDeadlineTimer{} = PollDeadlineTimer.sync(nil, [poll], DateTime.utc_now())

    poll_id = poll.id
    assert_receive {:poll_deadline_reached, ^poll_id}, 1_000
  end

  test "arms for the earliest of several deadlines" do
    now = DateTime.utc_now()
    sooner = open_poll(DateTime.add(now, 1, :hour))
    later = open_poll(DateTime.add(now, 2, :hour))

    timer = PollDeadlineTimer.sync(nil, [later, sooner], now)

    assert timer.deadline == sooner.deadline_at
    assert_in_delta Process.read_timer(timer.ref), :timer.hours(1), 1_000
  end

  test "arms nothing when no poll has a deadline still ahead" do
    now = DateTime.utc_now()

    polls = [
      open_poll(nil),
      open_poll(DateTime.add(now, -1, :minute)),
      build(:poll, status: :cancelled, deadline_at: DateTime.add(now, 1, :hour))
    ]

    assert PollDeadlineTimer.sync(nil, polls, now) == nil
  end

  test "keeps a running timer when the deadline has not moved" do
    now = DateTime.utc_now()
    poll = open_poll(DateTime.add(now, 1, :hour))

    timer = PollDeadlineTimer.sync(nil, [poll], now)

    assert PollDeadlineTimer.sync(timer, [poll], now).ref == timer.ref
  end

  test "replaces the timer when the host moves the deadline" do
    now = DateTime.utc_now()
    poll = open_poll(DateTime.add(now, 1, :hour))
    timer = PollDeadlineTimer.sync(nil, [poll], now)

    moved = %{poll | deadline_at: DateTime.add(now, 3, :hour)}
    rearmed = PollDeadlineTimer.sync(timer, [moved], now)

    assert Process.read_timer(timer.ref) == false
    assert rearmed.deadline == moved.deadline_at
    assert_in_delta Process.read_timer(rearmed.ref), :timer.hours(3), 1_000
  end

  test "cancels the timer once nothing is left to close" do
    now = DateTime.utc_now()
    poll = open_poll(DateTime.add(now, 1, :hour))
    timer = PollDeadlineTimer.sync(nil, [poll], now)

    assert PollDeadlineTimer.sync(timer, [%{poll | status: :cancelled}], now) == nil
    assert Process.read_timer(timer.ref) == false
  end

  test "caps a wait longer than the timer allows, to re-arm on waking" do
    now = DateTime.utc_now()
    poll = open_poll(DateTime.add(now, 60, :day))

    timer = PollDeadlineTimer.sync(nil, [poll], now)

    assert Process.read_timer(timer.ref) <= PollDeadlineTimer.max_delay_ms()
    assert timer.deadline == poll.deadline_at
  end

  test "arms a fresh timer for the same deadline once the capped one has fired" do
    poll = open_poll(in_ms(60_000))

    fired = %PollDeadlineTimer{
      ref: Process.send_after(self(), :early, 0),
      deadline: poll.deadline_at
    }

    assert_receive :early

    rearmed = PollDeadlineTimer.sync(fired, [poll], DateTime.utc_now())

    assert rearmed.ref != fired.ref
    assert is_integer(Process.read_timer(rearmed.ref))
  end
end
