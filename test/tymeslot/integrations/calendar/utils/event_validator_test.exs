defmodule Tymeslot.Integrations.Calendar.Utils.EventValidatorTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Utils.EventValidator

  describe "validate/1 — timed events" do
    test "accepts a valid timed event with utc datetimes" do
      attrs = %{
        summary: "Standup",
        start_time: ~U[2026-04-10 09:00:00Z],
        end_time: ~U[2026-04-10 10:00:00Z]
      }

      assert {:ok, ^attrs} = EventValidator.validate(attrs)
    end

    test "rejects a timed event whose end is at or before its start" do
      attrs = %{
        start_time: ~U[2026-04-10 10:00:00Z],
        end_time: ~U[2026-04-10 09:00:00Z]
      }

      assert {:error, %Ecto.Changeset{}} = EventValidator.validate(attrs)
    end

    test "rejects a timed event missing start/end" do
      assert {:error, %Ecto.Changeset{}} = EventValidator.validate(%{summary: "No times"})
    end
  end

  describe "validate/1 — all-day events" do
    test "accepts an all-day event with Date start/end and all_day: true" do
      attrs = %{
        summary: "Holiday",
        all_day: true,
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-19]
      }

      assert {:ok, ^attrs} = EventValidator.validate(attrs)
    end

    test "treats Date-typed start/end as all-day even without the explicit flag" do
      attrs = %{
        summary: "Holiday",
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-18]
      }

      assert {:ok, ^attrs} = EventValidator.validate(attrs)
    end

    test "rejects an all-day event whose end date precedes its start date" do
      attrs = %{
        all_day: true,
        start_time: ~D[2026-04-19],
        end_time: ~D[2026-04-18]
      }

      assert {:error, %Ecto.Changeset{}} = EventValidator.validate(attrs)
    end
  end
end
