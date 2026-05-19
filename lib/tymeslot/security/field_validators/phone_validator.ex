defmodule Tymeslot.Security.FieldValidators.PhoneValidator do
  @moduledoc """
  Lightweight phone-number validation.

  Accepts international (+1 …) and local forms with spaces, dashes,
  parentheses, leading +, and optional ext.. Rejects anything containing
  alphabetic letters outside the literal "ext". Length 4..30 digits after
  normalising. Does not look up country dial-codes.
  """

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank_result(opts)
  def validate("", opts), do: blank_result(opts)

  def validate(value, _) when is_binary(value) do
    trimmed = String.trim(value)

    # Strip a single "ext"/"x" segment so we don't count its digits as part of the main number.
    main = Regex.replace(~r/\s*(ext\.?|x|extension)\s*\d+\s*$/i, trimmed, "")

    cond do
      Regex.match?(~r/[A-Za-z]/, main) ->
        {:error, "Phone number contains invalid characters"}

      not Regex.match?(~r/^\+?[\d\s\-\(\)\.]+$/, main) ->
        {:error, "Phone number contains invalid characters"}

      digit_count(main) < 4 ->
        {:error, "Phone number is too short"}

      digit_count(main) > 30 ->
        {:error, "Phone number is too long"}

      true ->
        :ok
    end
  end

  def validate(_, _), do: {:error, "Phone number must be text"}

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Phone number is required"}
    else
      :ok
    end
  end

  defp digit_count(s), do: s |> String.replace(~r/\D/, "") |> String.length()
end
