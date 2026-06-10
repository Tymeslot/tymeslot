defmodule Tymeslot.Security.FieldValidators.DateValidator do
  @moduledoc "Validates ISO-8601 dates with optional min/max bounds."

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, opts) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         :ok <- check_bound(date, Keyword.get(opts, :min), :min),
         :ok <- check_bound(date, Keyword.get(opts, :max), :max) do
      :ok
    else
      {:error, :invalid_format} -> {:error, "Date must be in YYYY-MM-DD format"}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _other -> {:error, "Date is invalid"}
    end
  end

  def validate(_value, _opts), do: {:error, "Date must be text"}

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Date is required"}, else: :ok
  end

  defp check_bound(_date, nil, _dir), do: :ok

  defp check_bound(date, bound, :min) when is_binary(bound) do
    case Date.from_iso8601(bound) do
      {:ok, b} ->
        if Date.compare(date, b) in [:eq, :gt],
          do: :ok,
          else: {:error, "Date is before the earliest allowed date"}

      _err ->
        {:error, "Date range configuration is invalid"}
    end
  end

  defp check_bound(date, bound, :max) when is_binary(bound) do
    case Date.from_iso8601(bound) do
      {:ok, b} ->
        if Date.compare(date, b) in [:eq, :lt],
          do: :ok,
          else: {:error, "Date is after the latest allowed date"}

      _err ->
        {:error, "Date range configuration is invalid"}
    end
  end

  # A non-binary bound (e.g. a legacy integer from before date bounds were
  # stored as ISO strings) can't express a date — treat it as no bound
  # rather than crashing the booking flow.
  defp check_bound(_date, _bound, _dir), do: :ok
end
