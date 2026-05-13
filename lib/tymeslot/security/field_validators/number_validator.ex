defmodule Tymeslot.Security.FieldValidators.NumberValidator do
  @moduledoc "Validates integer or decimal numbers with optional min/max."

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, opts) when is_binary(value) do
    case parse(value) do
      {:ok, n} -> check_bounds(n, opts)
      :error -> {:error, "Number is not valid"}
    end
  end

  def validate(value, opts) when is_number(value), do: check_bounds(value, opts)
  def validate(_, _), do: {:error, "Number must be numeric"}

  defp parse(value) do
    case Float.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Integer.parse(value) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp check_bounds(n, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      is_number(min) and n < min -> {:error, "Number must be at least #{min}"}
      is_number(max) and n > max -> {:error, "Number must be at most #{max}"}
      true -> :ok
    end
  end

  defp blank(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Number is required"}, else: :ok
  end
end
