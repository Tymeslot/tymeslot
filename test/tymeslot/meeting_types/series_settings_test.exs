defmodule Tymeslot.MeetingTypes.SeriesSettingsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries.Check
  alias Tymeslot.BookingSeries.Dates
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

  describe "the year a recurring series must fall within" do
    defp rhythm(frequency, interval, min, max) do
      changeset(
        recurring(%{
          series_frequency: frequency,
          series_interval: interval,
          series_min_occurrences: min,
          series_max_occurrences: max
        })
      )
    end

    test "every 4 weeks fits 14 sessions (364 days) and refuses 15 (392 days)" do
      assert rhythm(:weekly, 4, 2, 14).valid?

      cs = rhythm(:weekly, 4, 2, 15)
      refute cs.valid?
      assert [{_msg, opts}] = errors(cs, :series_max_occurrences)
      assert opts[:max] == 14
      assert errors(cs, :series_min_occurrences) == []
    end

    test "every 3 weeks fits 18 sessions and refuses 19" do
      assert rhythm(:weekly, 3, 2, 18).valid?
      refute rhythm(:weekly, 3, 2, 19).valid?
    end

    test "monthly fits 12 sessions (eleven steps) and refuses 13, which twelve steps can overrun" do
      assert rhythm(:monthly, 1, 2, 12).valid?

      cs = rhythm(:monthly, 1, 2, 13)
      assert [{_msg, opts}] = errors(cs, :series_max_occurrences)
      assert opts[:max] == 12
    end

    test "every 2, 3 and 4 months fit 6, 4 and 3 sessions" do
      for {interval, fitting} <- [{2, 6}, {3, 4}, {4, 3}] do
        assert rhythm(:monthly, interval, 2, fitting).valid?
        refute rhythm(:monthly, interval, 2, fitting + 1).valid?
      end
    end

    test "a minimum that cannot fit is refused on the minimum too" do
      cs = rhythm(:monthly, 1, 13, 14)

      assert [{_msg, opts}] = errors(cs, :series_min_occurrences)
      assert opts[:max] == 12
      assert [{_msg, _opts}] = errors(cs, :series_max_occurrences)
    end

    test "a fixed count that cannot fit is reported once, on the maximum" do
      cs = rhythm(:monthly, 1, 13, 13)

      assert errors(cs, :series_min_occurrences) == []
      assert [{_msg, _opts}] = errors(cs, :series_max_occurrences)
    end

    test "the largest count allowed fits the span from every first date of a year" do
      span = Check.span_days()

      overruns =
        for zone <- ["Europe/Berlin", "Australia/Sydney"],
            frequency <- [:daily, :weekly, :monthly],
            interval <- SeriesSettings.intervals(),
            count = min(SeriesSettings.max_fitting_count(frequency, interval), 26),
            day <- 0..365,
            first = DateTime.new!(Date.add(~D[2027-01-01], day), ~T[17:30:00], zone),
            first = DateTime.shift_zone!(first, "Etc/UTC"),
            last = List.last(Dates.recurring_starts(first, frequency, interval, count, zone)),
            DateTime.compare(last, DateTime.add(first, span, :day)) == :gt,
            do: {zone, frequency, interval, DateTime.to_date(first)}

      assert overruns == []
    end

    test "one more session than allowed overruns the span from some first date" do
      span = Check.span_days()

      fits_everywhere? = fn frequency, interval, count ->
        Enum.all?(0..365, fn day ->
          first = DateTime.new!(Date.add(~D[2027-01-01], day), ~T[17:30:00], "Etc/UTC")
          last = List.last(Dates.recurring_starts(first, frequency, interval, count, "Etc/UTC"))
          DateTime.compare(last, DateTime.add(first, span, :day)) != :gt
        end)
      end

      capped =
        for frequency <- [:weekly, :monthly],
            interval <- SeriesSettings.intervals(),
            count = SeriesSettings.max_fitting_count(frequency, interval),
            count < 26,
            do: {frequency, interval, count}

      assert capped != []
      # A cap one session short of what always fits would refuse a bookable series.
      assert Enum.filter(capped, fn {f, i, c} -> fits_everywhere?.(f, i, c + 1) end) == []
    end

    test "daily rhythms always fit the count bounds" do
      assert rhythm(:daily, 4, 26, 26).valid?
    end

    test "a flexible series is not held to a rhythm" do
      cs =
        changeset(%{
          series_mode: :flexible,
          series_frequency: :monthly,
          series_min_occurrences: 26,
          series_max_occurrences: 26
        })

      assert cs.valid?
    end
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

  test "a paid group type cannot offer a series" do
    assert SeriesSettings.conflicts(%{
             series_mode: :flexible,
             payment_required: true,
             max_participants: 5
           }) == [{:payment_required, "Paid group meeting types cannot be booked as a series."}]
  end

  test "a paid one-to-one type and a free group type can" do
    assert SeriesSettings.conflicts(%{
             series_mode: :flexible,
             payment_required: true,
             max_participants: 1
           }) == []

    assert SeriesSettings.conflicts(%{
             series_mode: :flexible,
             payment_required: false,
             max_participants: 5
           }) == []
  end

  test "making a group series paid is refused on the payment field" do
    cs =
      changeset(
        %{payment_required: true, price_cents: 5000},
        stored_series(%{series_mode: :recurring, series_frequency: :weekly, max_participants: 5})
      )

    assert {"Paid group meeting types cannot be booked as a series.", []} in errors(
             cs,
             :payment_required
           )

    assert errors(cs, :series_mode) == []
  end

  test "making a paid series a group is refused on the payment field" do
    cs =
      changeset(
        %{max_participants: 5},
        stored_series(%{
          series_mode: :recurring,
          series_frequency: :weekly,
          payment_required: true,
          price_cents: 5000,
          max_participants: 1
        })
      )

    assert {"Paid group meeting types cannot be booked as a series.", []} in errors(
             cs,
             :payment_required
           )
  end

  describe "email confirmation" do
    @verification_message "Meeting types that ask invitees to confirm their email cannot be booked as a series."

    test "a series cannot be switched on for a type that asks invitees to confirm their email" do
      stored = %MeetingTypeSchema{
        name: "Course",
        duration_minutes: 30,
        user_id: 1,
        requires_email_verification: true
      }

      cs = changeset(recurring(%{}), stored)

      refute cs.valid?
      assert [{@verification_message, _opts}] = errors(cs, :series_mode)
      assert errors(cs, :requires_email_verification) == []
    end

    test "a series type cannot be made to ask invitees to confirm their email" do
      cs = changeset(%{requires_email_verification: true}, stored_series())

      refute cs.valid?
      assert [{@verification_message, _opts}] = errors(cs, :requires_email_verification)
      assert errors(cs, :series_mode) == []
    end

    test "a new type with both is refused, and either alone is valid" do
      refute changeset(recurring(%{requires_email_verification: true})).valid?
      assert changeset(recurring(%{})).valid?
      assert changeset(%{requires_email_verification: true}).valid?
    end

    test "turning email confirmation off a type saved with both is valid" do
      stored = stored_series(%{requires_email_verification: true})

      assert changeset(%{requires_email_verification: false}, stored).valid?
      assert changeset(%{series_mode: nil}, stored).valid?
    end

    test "a type saved with both is not offered the series, and books single sessions" do
      type = stored_series(%{series_required: true, requires_email_verification: true})

      assert SeriesSettings.offer(type) == %{offered?: false, single_allowed?: true}
    end
  end

  test "a paid group type saved with a series is not offered it, and books single sessions" do
    paid_group =
      stored_series(%{series_required: true, payment_required: true, max_participants: 5})

    paid_one_to_one = stored_series(%{payment_required: true, max_participants: 1})

    assert SeriesSettings.offer(paid_group) == %{offered?: false, single_allowed?: true}
    assert SeriesSettings.offered?(paid_one_to_one)
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

  defp limited(series, limits) do
    %{series_interval: 1, series_max_occurrences: 8}
    |> recurring()
    |> Map.merge(series)
    |> Map.merge(limits)
  end

  describe "limit_conflicts/1" do
    test "a weekly series needs more than a monthly cap of 2" do
      assert SeriesSettings.limit_conflicts(limited(%{}, %{max_bookings_per_month: 2})) ==
               [{:per_month, 2, 5}]
    end

    test "a daily series is checked against the weekly and the monthly cap" do
      type =
        limited(%{series_frequency: :daily}, %{
          max_bookings_per_week: 3,
          max_bookings_per_month: 6
        })

      assert SeriesSettings.limit_conflicts(type) == [{:per_week, 3, 7}, {:per_month, 6, 8}]
    end

    test "the sessions needed are capped at the series' maximum count" do
      type =
        limited(%{series_frequency: :daily, series_max_occurrences: 4}, %{
          max_bookings_per_week: 4
        })

      assert SeriesSettings.limit_conflicts(type) == []

      assert [{:per_week, 3, 4}] =
               SeriesSettings.limit_conflicts(%{type | max_bookings_per_week: 3})
    end

    test "the interval spreads the sessions out" do
      every_other_week = limited(%{series_interval: 2}, %{max_bookings_per_month: 2})
      assert SeriesSettings.limit_conflicts(every_other_week) == [{:per_month, 2, 3}]

      every_other_day =
        limited(%{series_frequency: :daily, series_interval: 2}, %{max_bookings_per_week: 4})

      assert SeriesSettings.limit_conflicts(every_other_day) == []

      assert [{:per_week, 3, 4}] =
               SeriesSettings.limit_conflicts(%{every_other_day | max_bookings_per_week: 3})
    end

    test "a cap that fits, or no cap, raises nothing" do
      assert SeriesSettings.limit_conflicts(limited(%{}, %{max_bookings_per_month: 5})) == []
      assert SeriesSettings.limit_conflicts(limited(%{}, %{max_bookings_per_month: nil})) == []
    end

    test "monthly and flexible series are never checked" do
      monthly =
        limited(%{series_frequency: :monthly}, %{
          max_bookings_per_week: 1,
          max_bookings_per_month: 1
        })

      assert SeriesSettings.limit_conflicts(monthly) == []

      flexible =
        limited(%{series_mode: :flexible}, %{max_bookings_per_week: 1, max_bookings_per_month: 1})

      assert SeriesSettings.limit_conflicts(flexible) == []

      assert SeriesSettings.limit_conflicts(%{series_mode: nil, max_bookings_per_month: 1}) == []
    end
  end

  describe "form_attrs/1" do
    test "parses the posted series" do
      assert SeriesSettings.form_attrs(%{
               "series_mode" => "recurring",
               "series_frequency" => "weekly",
               "series_interval" => "2",
               "series_min_occurrences" => "4",
               "series_max_occurrences" => "6",
               "series_required" => "false"
             }) == %{
               series_mode: :recurring,
               series_frequency: :weekly,
               series_interval: 2,
               series_min_occurrences: 4,
               series_max_occurrences: 6,
               series_required: false
             }
    end

    test "a blank or unknown mode is no series, and a bad number is nil" do
      assert %{series_mode: nil} = SeriesSettings.form_attrs(%{"series_mode" => ""})

      assert %{series_mode: nil, series_min_occurrences: nil} =
               SeriesSettings.form_attrs(%{
                 "series_mode" => "weekly",
                 "series_min_occurrences" => "x"
               })
    end

    test "params without a series mode leave the series alone" do
      assert SeriesSettings.form_attrs(%{"name" => "Course"}) == %{}
    end
  end
end
