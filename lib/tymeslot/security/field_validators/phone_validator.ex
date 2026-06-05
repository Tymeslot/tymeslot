defmodule Tymeslot.Security.FieldValidators.PhoneValidator do
  @moduledoc """
  Lightweight phone-number validation.

  Accepts international (+1 …) and local forms with spaces, dashes,
  parentheses, leading +, and optional ext.. Rejects anything containing
  alphabetic letters outside the literal "ext". Does not look up country
  dial-codes.

  Length is bounded by digit count after normalising (the optional ext is
  stripped first). E.164 caps a real phone number at 15 digits; we allow a
  small buffer above that for legitimate variations we may not have in mind —
  e.g. a leading `00` international prefix dialled in place of `+`, or a
  retained national trunk `0` — while still rejecting clearly bogus strings
  like a 20-digit run. The minimum keeps short internal/extension codes valid.
  """

  # E.164 max (15) + a 2-digit buffer for "00"-prefixed / trunk-`0` variations.
  @max_digits 17
  @min_digits 4

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank_result(opts)
  def validate("", opts), do: blank_result(opts)

  def validate(value, _opts) when is_binary(value) do
    trimmed = String.trim(value)

    # Strip a single "ext"/"x" segment so we don't count its digits as part of the main number.
    main = Regex.replace(~r/\s*(ext\.?|x|extension)\s*\d+\s*$/i, trimmed, "")

    cond do
      Regex.match?(~r/[A-Za-z]/, main) ->
        {:error, "Phone number contains invalid characters"}

      not Regex.match?(~r/^\+?[\d\s\-\(\)\.]+$/, main) ->
        {:error, "Phone number contains invalid characters"}

      digit_count(main) < @min_digits ->
        {:error, "Phone number is too short"}

      digit_count(main) > @max_digits ->
        {:error, "Phone number is too long"}

      true ->
        :ok
    end
  end

  def validate(_value, _opts), do: {:error, "Phone number must be text"}

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Phone number is required"}
    else
      :ok
    end
  end

  defp digit_count(s), do: s |> String.replace(~r/\D/, "") |> String.length()
end
