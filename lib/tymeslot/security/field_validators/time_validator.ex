defmodule Tymeslot.Security.FieldValidators.TimeValidator do
  @moduledoc """
  Validates ISO-8601 times (HH:MM or HH:MM:SS) with optional min/max
  bounds. Bounds are supplied as time strings (the host stores them as
  strings on the field definition); a non-parseable or non-string bound
  is treated as absent rather than crashing the booking flow.
  """

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, opts) when is_binary(value) do
    case parse_time(value) do
      {:ok, time} ->
        with :ok <- check_bound(time, Keyword.get(opts, :min), :min) do
          check_bound(time, Keyword.get(opts, :max), :max)
        end

      :error ->
        {:error, "Time must be in HH:MM format"}
    end
  end

  def validate(_value, _opts), do: {:error, "Time must be text"}

  defp parse_time(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/^\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/, trimmed) do
      # Time.from_iso8601 requires seconds; pad if missing.
      padded =
        if length(String.split(trimmed, ":")) == 2,
          do: trimmed <> ":00",
          else: trimmed

      case Time.from_iso8601(padded) do
        {:ok, time} -> {:ok, time}
        _err -> :error
      end
    else
      :error
    end
  end

  defp check_bound(_time, nil, _dir), do: :ok

  defp check_bound(time, bound, dir) when is_binary(bound) do
    case parse_time(bound) do
      {:ok, b} -> compare_bound(time, b, dir)
      :error -> {:error, "Time range configuration is invalid"}
    end
  end

  # Non-string bound can't express a time — treat as no bound.
  defp check_bound(_time, _bound, _dir), do: :ok

  defp compare_bound(time, bound, :min) do
    if Time.compare(time, bound) in [:eq, :gt],
      do: :ok,
      else: {:error, "Time is before the earliest allowed time"}
  end

  defp compare_bound(time, bound, :max) do
    if Time.compare(time, bound) in [:eq, :lt],
      do: :ok,
      else: {:error, "Time is after the latest allowed time"}
  end

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Time is required"}, else: :ok
  end
end
