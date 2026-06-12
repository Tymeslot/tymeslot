defmodule Tymeslot.Security.FieldValidators.NumberValidator do
  @moduledoc """
  Validates integer or decimal numbers with optional min/max bounds.

  Input length is capped before parsing. `Float.parse/1` raises an
  `ArgumentError` on IEEE-754 overflow for very long digit strings (≥ 309
  significant digits) and on huge exponent forms such as `"1e400"`, so an
  unbounded booker-supplied string is a remote process-kill primitive. We
  reject anything longer than `@max_length` outright and guard every parse
  so overflow returns `{:error, …}` rather than crashing the LiveView.

  Bounds (`:min`/`:max`) may be supplied as numbers or as numeric strings —
  the host stores them as strings on the field definition. Non-numeric
  bounds are treated as absent rather than crashing.
  """

  # A signed 308-digit integer plus a decimal fraction comfortably fits; 320
  # leaves headroom for sign, decimal point and a short fractional part while
  # staying well below the ~309-significant-digit float overflow threshold.
  @max_length 320

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, opts) when is_binary(value) do
    if String.length(value) > @max_length do
      {:error, "Number is too long"}
    else
      case parse(value) do
        {:ok, n} -> check_bounds(n, opts)
        :error -> {:error, "Number is not valid"}
      end
    end
  end

  def validate(value, opts) when is_number(value), do: check_bounds(value, opts)
  def validate(_value, _opts), do: {:error, "Number must be numeric"}

  # `Float.parse/1` and `Integer.parse/1` raise `ArgumentError` on
  # pathological input — IEEE-754 overflow for ≥ 309-digit strings, and
  # out-of-range exponent forms such as `"1e400"`. Wrap both so any such
  # raise degrades to a validation error instead of killing the caller.
  defp parse(value) do
    case safe_float_parse(value) do
      {n, ""} -> {:ok, n}
      _err -> parse_integer(value)
    end
  end

  # `Float.parse/1` raises `ArgumentError` on IEEE-754 overflow (≥ 309-digit
  # strings). Such a string can still be a perfectly valid (large) integer, so
  # on overflow we fall through to `Integer.parse/1` rather than rejecting.
  defp safe_float_parse(value) do
    Float.parse(value)
  rescue
    ArgumentError -> :error
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp check_bounds(n, opts) do
    min = numeric_bound(Keyword.get(opts, :min))
    max = numeric_bound(Keyword.get(opts, :max))

    cond do
      is_number(min) and n < min -> {:error, "Number must be at least #{min}"}
      is_number(max) and n > max -> {:error, "Number must be at most #{max}"}
      true -> :ok
    end
  end

  defp numeric_bound(bound) when is_number(bound), do: bound

  defp numeric_bound(bound) when is_binary(bound) do
    case parse(bound) do
      {:ok, n} -> n
      :error -> nil
    end
  end

  defp numeric_bound(_bound), do: nil

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Number is required"}, else: :ok
  end
end
