defmodule Tymeslot.Notifications.RelevanceTest do
  use ExUnit.Case, async: true

  @moduletag :notifications

  alias Tymeslot.Notifications.Relevance

  @start ~U[2026-03-10 09:00:00Z]
  @week 7 * 86_400

  describe "request_expiry/1" do
    test "a request whose deadline fell at its start stays owed for a week past it" do
      request = %{first_announced_at: nil, start_time: @start, approval_deadline_at: @start}

      assert Relevance.request_expiry(request) == DateTime.add(@start, @week, :second)
    end

    test "a request expiring long before its meeting stays owed until the meeting starts" do
      deadline = DateTime.add(@start, -30, :day)
      request = %{first_announced_at: nil, start_time: @start, approval_deadline_at: deadline}

      assert Relevance.request_expiry(request) == @start
    end

    test "a booking a reschedule sent back into the gate is owed however late" do
      regated = %{
        first_announced_at: DateTime.add(@start, -60, :day),
        start_time: @start,
        approval_deadline_at: @start
      }

      assert Relevance.request_expiry(regated) == nil
    end
  end

  describe "series_expiry/1" do
    test "a series whose last session starts at its deadline stays owed for a week past it" do
      sessions = [
        %{first_announced_at: nil, start_time: @start, approval_deadline_at: @start},
        %{
          first_announced_at: nil,
          start_time: DateTime.add(@start, 1, :hour),
          approval_deadline_at: @start
        }
      ]

      assert Relevance.series_expiry(sessions) == DateTime.add(@start, @week, :second)
    end

    test "a series with sessions far ahead stays owed until the last one starts" do
      last = DateTime.add(@start, 60, :day)

      sessions = [
        %{first_announced_at: nil, start_time: @start, approval_deadline_at: @start},
        %{first_announced_at: nil, start_time: last, approval_deadline_at: @start}
      ]

      assert Relevance.series_expiry(sessions) == last
    end
  end
end
