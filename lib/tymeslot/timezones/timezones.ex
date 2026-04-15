defmodule Tymeslot.Timezones do
  @moduledoc """
  Public API for timezone operations.

  Delegates to focused sub-modules for data access, formatting, and validation.
  Callers should alias this single module.
  """

  alias Tymeslot.Timezones.{Data, Formatting}

  defdelegate all_options(), to: Data
  defdelegate search(term), to: Data
  defdelegate country_code(timezone_id), to: Data
  defdelegate normalize(timezone_id), to: Data
  defdelegate sanitize(timezone), to: Data
  defdelegate valid?(timezone_id), to: Data
  defdelegate valid_ids(), to: Data
  defdelegate flag_exists?(country_code), to: Data

  defdelegate format(timezone_id), to: Formatting
  defdelegate utc_offset(timezone_id), to: Formatting
  defdelegate format_utc_offset(seconds), to: Formatting
end
