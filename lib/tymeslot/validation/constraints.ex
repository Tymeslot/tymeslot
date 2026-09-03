defmodule Tymeslot.Validation.Constraints do
  @moduledoc """
  Centralised validation constraints for the Tymeslot application.

  This module is the single source of truth for numeric bounds, length limits,
  and Ecto-ready option lists used across schemas and domain modules. The
  validation architecture has three layers:

  1. **This module** defines the values (bounds, ranges, limits).
  2. **Field validators** (`Tymeslot.Security.FieldValidators.*`) own format
     rules (regex patterns, complexity checks).
  3. **Schemas** enforce constraints at the database boundary by calling
     `validate_number(field, Constraints.some_opts())` and delegating format
     checks to shared changeset validators.
  4. **Domain InputValidation modules** handle sanitisation, casting, rate
     limiting, and business rules not expressible in changesets.

  A validation rule lives in exactly one layer. If you need to change a bound,
  change it here — schemas and domain modules will pick it up automatically.
  """

  # Scheduling bounds

  @spec buffer_minutes_range() :: Range.t()
  def buffer_minutes_range, do: 0..120

  @spec advance_booking_days_range() :: Range.t()
  def advance_booking_days_range, do: 1..365

  @spec min_advance_hours_range() :: Range.t()
  def min_advance_hours_range, do: 0..168

  @spec duration_minutes_range() :: Range.t()
  def duration_minutes_range, do: 1..480

  @spec slot_interval_minutes_range() :: Range.t()
  def slot_interval_minutes_range, do: 5..480

  @spec booking_limit_range() :: Range.t()
  def booking_limit_range, do: 1..500

  @doc """
  How long a host may take to answer a booking request, in hours.

  The lower bound is one hour rather than zero: a window a request cannot
  realistically be answered within is a request that always expires, which is
  worse for the invitee than not offering approval at all. The upper bound is
  two weeks, past which the hold on the slot costs more than the vetting is
  worth.
  """
  @spec approval_window_hours_range() :: Range.t()
  def approval_window_hours_range, do: 1..336

  @doc """
  How much a host may write when declining a booking request.

  The note is quoted verbatim into the invitee's email, so the cap is a
  boundary on what reaches a third party, not a storage limit: it is enforced
  where the reason is written, and mirrored as a `maxlength` on both places a
  host can type one.
  """
  @spec decline_reason_max_length() :: pos_integer()
  def decline_reason_max_length, do: 500

  @doc """
  The approval window applied when a meeting type stores none.

  A day is long enough to cover an overnight or a weekend gap on either side of
  a working day, and short enough that an invitee is not left waiting without
  resolution.
  """
  @spec default_approval_window_hours() :: pos_integer()
  def default_approval_window_hours, do: 24

  @doc "The booking-limit fields, in day/week/month order."
  @spec booking_limit_fields() :: [atom()]
  def booking_limit_fields,
    do: [:max_bookings_per_day, :max_bookings_per_week, :max_bookings_per_month]

  @doc """
  The scheduling policy applied when no availability schedule can be resolved.

  These are also the column defaults on `availability_schedules`, pinned by
  `Tymeslot.Availability.AvailabilityScheduleSchemaTest`. A caller with no
  schedule and a schedule saved without explicit values must agree on what the
  rules are, or the slots offered on a half-configured account would differ from
  the ones its bookings are validated against.
  """
  @spec scheduling_policy_defaults() :: %{
          buffer_minutes: non_neg_integer(),
          min_advance_hours: non_neg_integer(),
          advance_booking_days: pos_integer()
        }
  def scheduling_policy_defaults,
    do: %{buffer_minutes: 15, min_advance_hours: 3, advance_booking_days: 90}

  # Ecto-ready options (for validate_number/3)

  @spec buffer_minutes_opts() :: keyword()
  def buffer_minutes_opts do
    range = buffer_minutes_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec advance_booking_days_opts() :: keyword()
  def advance_booking_days_opts do
    range = advance_booking_days_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec min_advance_hours_opts() :: keyword()
  def min_advance_hours_opts do
    range = min_advance_hours_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec duration_minutes_opts() :: keyword()
  def duration_minutes_opts do
    range = duration_minutes_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec approval_window_hours_opts() :: keyword()
  def approval_window_hours_opts do
    range = approval_window_hours_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec slot_interval_minutes_opts() :: keyword()
  def slot_interval_minutes_opts do
    range = slot_interval_minutes_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @spec booking_limit_opts() :: keyword()
  def booking_limit_opts do
    range = booking_limit_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @doc "Minimum duration exposed in the meeting type form (step=5, so 1-4 min is impractical)."
  @spec duration_minutes_form_min() :: pos_integer()
  def duration_minutes_form_min, do: 5

  # Field lengths

  @spec name_length_range() :: Range.t()
  def name_length_range, do: 1..100

  @spec integration_name_length_range() :: Range.t()
  def integration_name_length_range, do: 2..100

  @spec webhook_name_length_range() :: Range.t()
  def webhook_name_length_range, do: 1..255

  @spec webhook_name_length_opts() :: keyword()
  def webhook_name_length_opts do
    range = webhook_name_length_range()
    [min: range.first, max: range.last]
  end

  @spec url_max_length() :: pos_integer()
  def url_max_length, do: 2048

  @spec username_length_range() :: Range.t()
  def username_length_range, do: 3..30

  @spec password_length_range() :: Range.t()
  def password_length_range, do: 8..80

  @spec message_length_range() :: Range.t()
  def message_length_range, do: 10..2000

  @spec description_max_length() :: pos_integer()
  def description_max_length, do: 500

  @spec name_length_opts() :: keyword()
  def name_length_opts do
    range = name_length_range()
    [min: range.first, max: range.last]
  end

  @spec break_label_max_length() :: pos_integer()
  def break_label_max_length, do: 50

  @spec override_reason_max_length() :: pos_integer()
  def override_reason_max_length, do: 100

  # Booking-page introductory text. The caps are the point at which the copy
  # stops behaving on the tightest viewport the booker supports: at 80
  # characters a Rhythm heading pushes the primary action to the bottom edge of
  # an 812x375 landscape phone, so 60 keeps roughly 30px of headroom. The
  # greeting and instruction render smaller and sit above the action, so they
  # take the looser cap.

  @spec booking_heading_max_length() :: pos_integer()
  def booking_heading_max_length, do: 60

  @spec booking_welcome_line_max_length() :: pos_integer()
  def booking_welcome_line_max_length, do: 80
end
