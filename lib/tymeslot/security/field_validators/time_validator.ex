defmodule Tymeslot.Security.FieldValidators.TimeValidator do
  @moduledoc "Validates ISO-8601 times (HH:MM or HH:MM:SS)."

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, _) when is_binary(value) do
    # Time.from_iso8601 requires seconds; pad if only HH:MM is given.
    padded =
      if String.contains?(value, ":") and length(String.split(value, ":")) == 2,
        do: value <> ":00",
        else: value

    case Time.from_iso8601(padded) do
      {:ok, _} -> :ok
      _ -> {:error, "Time must be in HH:MM format"}
    end
  end

  def validate(_, _), do: {:error, "Time must be text"}

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Time is required"}, else: :ok
  end
end
