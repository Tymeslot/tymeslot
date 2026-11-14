defmodule Tymeslot.MeetingTypes.SeriesSettingsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings

  @base %{name: "Course", duration_minutes: 30, user_id: 1}

  defp changeset(attrs, data \\ %MeetingTypeSchema{}) do
    MeetingTypeSchema.changeset(data, Map.merge(@base, attrs))
  end

  defp errors(changeset, field), do: Keyword.get_values(changeset.errors, field)

  defp recurring(attrs) do
    Map.merge(
      %{
        series_mode: :recurring,
        series_frequency: :weekly,
        series_min_occurrences: 4,
        series_max_occurrences: 4
      },
      attrs
    )
  end

  defp stored_series(extra \\ %{}) do
    struct!(
      MeetingTypeSchema,
      Map.merge(
        %{
          name: "Course",
          duration_minutes: 30,
          user_id: 1,
          series_mode: :flexible,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 5
        },
        extra
      )
    )
  end

  test "a valid recurring series is accepted" do
    cs = changeset(recurring(%{series_interval: 2}))

    assert cs.valid?
    assert Changeset.get_field(cs, :series_frequency) == :weekly
  end

  test "a recurring series needs a frequency" do
    cs = changeset(recurring(%{series_frequency: nil}))

    refute cs.valid?
    assert errors(cs, :series_frequency) != []
  end

  test "a recurring interval is 1 to 4" do
    assert changeset(recurring(%{series_interval: 4})).valid?

    for interval <- [0, 5] do
      cs = changeset(recurring(%{series_interval: interval}))
      refute cs.valid?
      assert errors(cs, :series_interval) != []
    end
  end

  test "the count range is 2 to 26 and ordered" do
    assert changeset(recurring(%{series_min_occurrences: 2, series_max_occurrences: 26})).valid?

    low = changeset(recurring(%{series_min_occurrences: 1, series_max_occurrences: 4}))
    assert errors(low, :series_min_occurrences) != []

    high = changeset(recurring(%{series_min_occurrences: 2, series_max_occurrences: 27}))
    assert errors(high, :series_max_occurrences) != []

    unordered = changeset(recurring(%{series_min_occurrences: 6, series_max_occurrences: 4}))
    assert errors(unordered, :series_max_occurrences) != []

    missing = changeset(recurring(%{series_min_occurrences: nil, series_max_occurrences: nil}))
    assert errors(missing, :series_min_occurrences) != []
    assert errors(missing, :series_max_occurrences) != []
  end

  test "a flexible series drops the frequency" do
    cs =
      changeset(%{
        series_mode: :flexible,
        series_frequency: :monthly,
        series_interval: 3,
        series_min_occurrences: 2,
        series_max_occurrences: 5
      })

    assert cs.valid?
    assert Changeset.get_field(cs, :series_frequency) == nil
    assert Changeset.get_field(cs, :series_interval) == 1
  end

  test "a one-off type cannot be a series" do
    cs = changeset(recurring(%{one_off: true}))
    assert [message] = errors(cs, :series_mode)
    assert elem(message, 0) == "One-off meeting types cannot be booked as a series."
  end

  test "a series type cannot be made one-off" do
    cs = changeset(%{one_off: true}, stored_series())

    refute cs.valid?
    assert [{"One-off meeting types cannot be booked as a series.", _opts}] = errors(cs, :one_off)
    assert errors(cs, :series_mode) == []
  end

  test "an invitation-only type cannot be a series" do
    forward = changeset(recurring(%{invitation_only: true}))

    assert [{"Invitation-only meeting types cannot be booked as a series.", _opts}] =
             errors(forward, :series_mode)

    reverse = changeset(%{invitation_only: true}, stored_series())

    assert [{"Invitation-only meeting types cannot be booked as a series.", _opts}] =
             errors(reverse, :invitation_only)
  end

  test "recurring mode is refused on fixed dates, flexible mode is allowed" do
    refused = changeset(recurring(%{fixed_dates: true}))
    assert [{"Meeting types with fixed dates" <> _rest, _opts}] = errors(refused, :series_mode)

    allowed =
      changeset(%{
        fixed_dates: true,
        series_mode: :flexible,
        series_min_occurrences: 2,
        series_max_occurrences: 3
      })

    assert errors(allowed, :series_mode) == []
  end

  test "turning the series off clears its settings" do
    stored =
      stored_series(%{
        series_mode: :recurring,
        series_frequency: :daily,
        series_interval: 3,
        series_required: false
      })

    cs = changeset(%{series_mode: nil}, stored)

    assert cs.valid?
    assert Changeset.get_field(cs, :series_mode) == nil
    assert Changeset.get_field(cs, :series_frequency) == nil
    assert Changeset.get_field(cs, :series_interval) == 1
    assert Changeset.get_field(cs, :series_min_occurrences) == nil
    assert Changeset.get_field(cs, :series_max_occurrences) == nil
    assert Changeset.get_field(cs, :series_required) == true
  end

  describe "runtime helpers" do
    test "series?/1 and count_range/1 read the stored settings" do
      assert SeriesSettings.series?(stored_series())
      refute SeriesSettings.series?(%MeetingTypeSchema{})
      assert SeriesSettings.count_range(stored_series()) == 2..5
    end

    test "offered? is true with access, and a single session is allowed only when not required" do
      type = stored_series(%{series_required: true})
      assert SeriesSettings.offered?(type)
      refute SeriesSettings.single_allowed?(type)
      assert SeriesSettings.single_allowed?(%{type | series_required: false})
    end

    test "offer/1 answers both at once" do
      type = stored_series(%{series_required: true})

      assert SeriesSettings.offer(type) == %{offered?: true, single_allowed?: false}

      assert SeriesSettings.offer(%{type | series_required: false}) ==
               %{offered?: true, single_allowed?: true}
    end

    test "a type without a series is never offered and always allows one session" do
      type = %MeetingTypeSchema{user_id: 1}
      refute SeriesSettings.offered?(type)
      assert SeriesSettings.single_allowed?(type)
    end
  end

  describe "when the checker denies access" do
    defmodule DenyChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    defmodule FailingChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :recurring_bookings_allowed), do: raise("checker down")
      def check_access(_user_id, _feature), do: :ok
    end

    test "offered? is false when the checker denies access" do
      setup_config(:tymeslot, feature_access_checker: DenyChecker)
      type = stored_series(%{series_required: true})

      assert SeriesSettings.series?(type)
      refute SeriesSettings.offered?(type)
      assert SeriesSettings.single_allowed?(type)
      assert SeriesSettings.offer(type) == %{offered?: false, single_allowed?: true}
    end

    test "offered? is false when the checker fails" do
      setup_config(:tymeslot, feature_access_checker: FailingChecker)
      refute SeriesSettings.offered?(stored_series())
    end
  end
end
