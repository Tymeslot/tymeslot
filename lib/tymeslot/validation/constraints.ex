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

  @spec booking_limit_range() :: Range.t()
  def booking_limit_range, do: 1..500

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

  @spec booking_limit_opts() :: keyword()
  def booking_limit_opts do
    range = booking_limit_range()
    [greater_than_or_equal_to: range.first, less_than_or_equal_to: range.last]
  end

  @doc "Minimum duration exposed in the meeting type form (step=5, so 1-4 min is impractical)."
  @spec duration_minutes_form_min() :: pos_integer()
  def duration_minutes_form_min, do: 5

  # Field lengths

  @spec email_max_length() :: pos_integer()
  def email_max_length, do: 254

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
end
