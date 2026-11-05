defmodule Tymeslot.Availability.DateOverridesTest do
  @moduledoc """
  `DateOverrides`: one date's exception to a schedule's weekly hours, reached
  only through the profile that owns the schedule, refused for a date already
  gone, and seen by the booking page as soon as it is written.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Availability.DateOverrides
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    host = create_bookable_profile(days: [1, 2, 3, 4, 5])
    saturday = next_bookable_weekday() |> Date.beginning_of_week(:monday) |> Date.add(5)
    Map.put(host, :saturday, saturday)
  end

  defp custom(date, from, to),
    do: %{date: date, override_type: :custom_hours, start_time: from, end_time: to}

  describe "upsert/3" do
    test "opens a closed day on its own hours", host do
      assert {:ok, %AvailabilityOverrideSchema{} = override} =
               DateOverrides.upsert(
                 host.profile_id,
                 host.schedule_id,
                 custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
               )

      assert override.override_type == :custom_hours
      assert override.start_time == ~T[10:00:00]

      assert {:ok, ^override} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.saturday)
    end

    test "replaces the date's override rather than adding a second", host do
      {:ok, first} =
        DateOverrides.upsert(
          host.profile_id,
          host.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:ok, second} =
               DateOverrides.upsert(host.profile_id, host.schedule_id, %{
                 date: host.saturday,
                 override_type: :unavailable
               })

      assert second.id == first.id
      assert second.override_type == :unavailable
      assert second.start_time == nil
      assert second.end_time == nil
    end

    test "the booking page sees the new hours at once", host do
      request = %{profile: host.profile, user_timezone: "Etc/UTC"}
      day = Date.to_iso8601(host.saturday)

      assert {:ok, %{^day => false}} =
               Offer.days_in_range(request, host.saturday, host.saturday, 30)

      {:ok, _override} =
        DateOverrides.upsert(
          host.profile_id,
          host.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:ok, %{^day => true}} =
               Offer.days_in_range(request, host.saturday, host.saturday, 30)
    end

    test "refuses another profile's schedule and writes nothing", host do
      other = create_bookable_profile()

      assert {:error, :not_found} =
               DateOverrides.upsert(
                 host.profile_id,
                 other.schedule_id,
                 custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
               )

      assert {:ok, nil} = DateOverrides.get(other.profile_id, other.schedule_id, host.saturday)
    end

    test "reads today on the owner's clock, not UTC's" do
      # 20:00 UTC on the 10th is already 05:00 on the 11th in Tokyo.
      ClockHelpers.freeze_clock(~U[2030-06-10 20:00:00Z])
      tokyo = create_bookable_profile(timezone: "Asia/Tokyo")

      assert {:error, :in_past} =
               DateOverrides.upsert(
                 tokyo.profile_id,
                 tokyo.schedule_id,
                 custom(~D[2030-06-10], ~T[10:00:00], ~T[12:00:00])
               )

      assert {:ok, %AvailabilityOverrideSchema{}} =
               DateOverrides.upsert(
                 tokyo.profile_id,
                 tokyo.schedule_id,
                 custom(~D[2030-06-11], ~T[10:00:00], ~T[12:00:00])
               )
    end

    test "refuses a date already gone in the owner's timezone", host do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {:error, :in_past} =
               DateOverrides.upsert(
                 host.profile_id,
                 host.schedule_id,
                 custom(yesterday, ~T[10:00:00], ~T[12:00:00])
               )
    end

    test "refuses custom hours that end before they start", host do
      assert {:error, %Changeset{} = changeset} =
               DateOverrides.upsert(
                 host.profile_id,
                 host.schedule_id,
                 custom(host.saturday, ~T[12:00:00], ~T[10:00:00])
               )

      assert Keyword.has_key?(changeset.errors, :end_time)
    end
  end

  describe "put_back/3" do
    test "writes for a date already gone, and only on an owned schedule", host do
      ClockHelpers.freeze_clock(
        DateTime.new!(Date.add(host.saturday, 1), ~T[00:30:00], "Etc/UTC")
      )

      assert {:ok, %AvailabilityOverrideSchema{start_time: ~T[10:00:00]}} =
               DateOverrides.put_back(
                 host.profile_id,
                 host.schedule_id,
                 custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
               )

      other = create_bookable_profile()

      assert {:error, :not_found} =
               DateOverrides.put_back(
                 host.profile_id,
                 other.schedule_id,
                 custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
               )
    end

    test "the booking page sees it at once", host do
      request = %{profile: host.profile, user_timezone: "Etc/UTC"}
      day = Date.to_iso8601(host.saturday)

      {:ok, _override} =
        DateOverrides.put_back(
          host.profile_id,
          host.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:ok, %{^day => true}} =
               Offer.days_in_range(request, host.saturday, host.saturday, 30)
    end
  end

  describe "get/3 and delete/3" do
    test "delete removes the date's override and is idempotent", host do
      request = %{profile: host.profile, user_timezone: "Etc/UTC"}
      day = Date.to_iso8601(host.saturday)

      {:ok, _override} =
        DateOverrides.upsert(
          host.profile_id,
          host.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:ok, %{^day => true}} =
               Offer.days_in_range(request, host.saturday, host.saturday, 30)

      assert :ok = DateOverrides.delete(host.profile_id, host.schedule_id, host.saturday)

      assert {:ok, %{^day => false}} =
               Offer.days_in_range(request, host.saturday, host.saturday, 30)

      assert {:ok, nil} = DateOverrides.get(host.profile_id, host.schedule_id, host.saturday)
      assert :ok = DateOverrides.delete(host.profile_id, host.schedule_id, host.saturday)
    end

    test "leave the date's extra times alone", host do
      for start <- [~T[07:00:00], ~T[19:00:00]] do
        {:ok, _extra} =
          AvailabilityOverrideQueries.create_override(%{
            schedule_id: host.schedule_id,
            date: host.saturday,
            override_type: :extra_hours,
            start_time: start,
            end_time: Time.add(start, 3600)
          })
      end

      {:ok, _override} =
        DateOverrides.upsert(
          host.profile_id,
          host.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:ok, %{override_type: :custom_hours}} =
               Repo.transaction(fn ->
                 {:ok, locked} =
                   DateOverrides.lock(host.profile_id, host.schedule_id, host.saturday)

                 locked
               end)

      assert :ok = DateOverrides.delete(host.profile_id, host.schedule_id, host.saturday)
      assert {:ok, nil} = DateOverrides.get(host.profile_id, host.schedule_id, host.saturday)

      assert [_first, _second] =
               AvailabilityOverrideQueries.list_extra_on(host.schedule_id, host.saturday)
    end

    test "neither reads nor deletes through another profile", host do
      other = create_bookable_profile()

      {:ok, _override} =
        DateOverrides.upsert(
          other.profile_id,
          other.schedule_id,
          custom(host.saturday, ~T[10:00:00], ~T[12:00:00])
        )

      assert {:error, :not_found} =
               DateOverrides.get(host.profile_id, other.schedule_id, host.saturday)

      assert {:error, :not_found} =
               DateOverrides.delete(host.profile_id, other.schedule_id, host.saturday)

      assert {:ok, %AvailabilityOverrideSchema{}} =
               DateOverrides.get(other.profile_id, other.schedule_id, host.saturday)
    end
  end
end
