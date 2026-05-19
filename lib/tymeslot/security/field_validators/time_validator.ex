defmodule Tymeslot.Security.FieldValidators.TimeValidator do
  @moduledoc "Validates ISO-8601 times (HH:MM or HH:MM:SS)."

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, _opts) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/^\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/, trimmed) do
      # Time.from_iso8601 requires seconds; pad if missing.
      padded =
        if length(String.split(trimmed, ":")) == 2,
          do: trimmed <> ":00",
          else: trimmed

      case Time.from_iso8601(padded) do
        {:ok, _} -> :ok
        _ -> {:error, "Time must be in HH:MM format"}
      end
    else
      {:error, "Time must be in HH:MM format"}
    end
  end

  def validate(_, _), do: {:error, "Time must be text"}

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Time is required"}, else: :ok
  end
end
