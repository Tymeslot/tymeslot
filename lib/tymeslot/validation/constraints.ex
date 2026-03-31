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

  # Ecto-ready options (for validate_number/3)

  @spec buffer_minutes_opts() :: keyword()
  def buffer_minutes_opts, do: [greater_than_or_equal_to: 0, less_than_or_equal_to: 120]

  @spec advance_booking_days_opts() :: keyword()
  def advance_booking_days_opts, do: [greater_than_or_equal_to: 1, less_than_or_equal_to: 365]

  @spec min_advance_hours_opts() :: keyword()
  def min_advance_hours_opts, do: [greater_than_or_equal_to: 0, less_than_or_equal_to: 168]

  @spec duration_minutes_opts() :: keyword()
  def duration_minutes_opts, do: [greater_than: 0, less_than_or_equal_to: 480]

  # Field lengths

  @spec email_max_length() :: pos_integer()
  def email_max_length, do: 254

  @spec name_length_range() :: Range.t()
  def name_length_range, do: 1..100

  @spec integration_name_length_range() :: Range.t()
  def integration_name_length_range, do: 2..100

  @spec webhook_name_length_range() :: Range.t()
  def webhook_name_length_range, do: 1..255

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
end
