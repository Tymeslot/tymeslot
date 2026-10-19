defmodule Tymeslot.Availability.PolicyValidation do
  @moduledoc """
  Instant-feedback validation for a schedule's booking policy (the buffers,
  how far ahead a guest may book and the minimum notice), as the editor
  submits each value on its own.

  Each range is read from `Tymeslot.Validation.Constraints`, the same source
  `AvailabilityScheduleSchema.policy_changeset/2` validates against, so the
  editor and the save path cannot disagree.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Validation.Constraints

  @type field ::
          :buffer_before_minutes
          | :buffer_after_minutes
          | :advance_booking_days
          | :min_advance_hours

  @fields [
    :buffer_before_minutes,
    :buffer_after_minutes,
    :advance_booking_days,
    :min_advance_hours
  ]

  @doc """
  Validates one submitted policy value: `{:ok, integer}` inside the field's
  range, otherwise `{:error, message}` in the current locale.
  """
  @spec validate(field(), String.t(), keyword()) :: {:ok, integer()} | {:error, String.t()}
  def validate(field, value_str, opts \\ []) when field in @fields do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized} <-
           UniversalSanitizer.sanitize_and_validate(value_str,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, value} <- check_range(field, sanitized) do
      log(field, "success", metadata, value: value)
      {:ok, value}
    else
      {:error, message} ->
        log(field, "failure", metadata, error: message)
        {:error, message}
    end
  end

  defp check_range(field, value_str) do
    %Range{first: min, last: max} = range(field)

    case Integer.parse(value_str) do
      {value, ""} when value >= min and value <= max ->
        {:ok, value}

      {value, ""} when value < min ->
        {:error,
         dgettext("dashboard_availability", "%{setting} must be at least %{min}",
           setting: label(field),
           min: min
         )}

      {_value, ""} ->
        {:error,
         dgettext("dashboard_availability", "%{setting} cannot be more than %{max}",
           setting: label(field),
           max: max
         )}

      _not_a_number ->
        {:error,
         dgettext("dashboard_availability", "%{setting} must be a whole number",
           setting: label(field)
         )}
    end
  end

  defp range(field) when field in [:buffer_before_minutes, :buffer_after_minutes],
    do: Constraints.buffer_minutes_range()

  defp range(:advance_booking_days), do: Constraints.advance_booking_days_range()
  defp range(:min_advance_hours), do: Constraints.min_advance_hours_range()

  defp label(:buffer_before_minutes), do: dgettext("dashboard_availability", "Buffer before")
  defp label(:buffer_after_minutes), do: dgettext("dashboard_availability", "Buffer after")

  defp label(:advance_booking_days),
    do: dgettext("dashboard_availability", "Advance booking days")

  defp label(:min_advance_hours), do: dgettext("dashboard_availability", "Minimum advance hours")

  defp log(field, outcome, metadata, details) do
    SecurityLogger.log_security_event(
      "#{field}_validation_#{outcome}",
      Map.merge(
        %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id]
        },
        Map.new(details)
      )
    )
  end
end
