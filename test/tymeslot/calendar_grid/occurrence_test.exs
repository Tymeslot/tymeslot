defmodule Tymeslot.CalendarGrid.OccurrenceTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.Occurrence

  describe "original_start/1 of a Google occurrence" do
    test "reads the UTC stamp its uid ends in, not where it shows now" do
      row = %{
        provider: "google",
        uid: "weekly@google.com_20261102T080000Z",
        provider_event_id: "weekly_20261102T080000Z",
        start_at: ~U[2026-11-02 10:00:00Z]
      }

      assert Occurrence.original_start(row) == {:ok, ~U[2026-11-02 08:00:00Z]}
    end

    test "reads an all-day stamp as the day" do
      row = %{provider: :google, uid: "days@google.com_20260604", provider_event_id: "x"}

      assert Occurrence.original_start(row) == {:ok, ~D[2026-06-04]}
    end

    test "falls back to the instance id when the uid carries no stamp" do
      row = %{provider: "google", uid: "weekly_x", provider_event_id: "weekly_20261102T080000Z"}

      assert Occurrence.original_start(row) == {:ok, ~U[2026-11-02 08:00:00Z]}
    end

    test "is unaddressable when neither carries one" do
      row = %{provider: "google", uid: "weekly", provider_event_id: "weekly"}

      assert Occurrence.original_start(row) == {:error, :unaddressable_occurrence}
    end
  end

  describe "original_start/1 of an Outlook occurrence" do
    test "reads the originalStart Graph states" do
      row = %{
        provider: "outlook",
        all_day: false,
        start_at: ~U[2026-11-02 10:00:00Z],
        provider_metadata: %{"type" => "exception", "originalStart" => "2026-11-02T08:00:00Z"}
      }

      assert Occurrence.original_start(row) == {:ok, ~U[2026-11-02 08:00:00Z]}
    end

    test "takes an unedited occurrence's own start" do
      row = %{
        provider: "outlook",
        all_day: false,
        start_at: ~U[2026-11-02 08:00:00Z],
        provider_metadata: %{"type" => "occurrence"}
      }

      assert Occurrence.original_start(row) == {:ok, ~U[2026-11-02 08:00:00Z]}
    end

    test "is unaddressable for an exception whose original start is not known" do
      row = %{
        provider: "outlook",
        all_day: false,
        start_at: ~U[2026-11-02 10:00:00Z],
        provider_metadata: %{"type" => "exception"}
      }

      assert Occurrence.original_start(row) == {:error, :unaddressable_occurrence}
    end
  end
end
