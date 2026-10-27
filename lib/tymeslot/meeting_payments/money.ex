defmodule Tymeslot.MeetingPayments.Money do
  @moduledoc """
  Amounts of money as integer minor units (cents), the way Stripe counts
  them, and the one place they are parsed from and formatted for people.

  A currency's minor units follow Stripe: most currencies have two decimal
  places, the zero-decimal ones (`jpy`, `krw`, ...) are counted in whole
  units, and the three-decimal ones (`bhd`, `kwd`, ...) in thousandths.
  Currency codes are lower-case ISO 4217, as Stripe sends them; any case is
  accepted.

  Formatting is deliberately not locale-aware: one symbol table, the sign
  before the symbol (`-€10.00`), a dot as the decimal separator and no
  thousands separator, in every language.
  """

  @zero_decimal ~w(bif clp djf gnf jpy kmf krw mga pyg rwf ugx vnd vuv xaf xof xpf)
  @three_decimal ~w(bhd jod kwd omr tnd)

  @symbols %{
    "eur" => "€",
    "usd" => "$",
    "gbp" => "£",
    "jpy" => "¥",
    "krw" => "₩",
    "cad" => "CA$",
    "aud" => "A$",
    "nzd" => "NZ$"
  }

  @type currency :: String.t()

  @doc """
  The number of decimal places `currency` is counted in: 0, 2 or 3.
  """
  @spec minor_units(currency()) :: 0 | 2 | 3
  def minor_units(currency) when is_binary(currency) do
    case String.downcase(currency) do
      code when code in @zero_decimal -> 0
      code when code in @three_decimal -> 3
      _two_decimal -> 2
    end
  end

  @doc """
  Parses an amount a person typed, in major units of `currency`, into minor
  units.

  One rule for every form: surrounding whitespace is ignored, the decimal
  separator is a dot or a comma, there are at most as many decimals as the
  currency has, and the amount is positive. Signs, exponents, thousands
  separators and anything else are rejected. A blank input is invalid; a
  form whose field is optional handles blank before calling this.

      iex> Money.parse("12,5", "eur")
      {:ok, 1250}
      iex> Money.parse("1000", "jpy")
      {:ok, 1000}
      iex> Money.parse("12.345", "eur")
      {:error, :invalid_amount}
  """
  @spec parse(String.t(), currency()) :: {:ok, pos_integer()} | {:error, :invalid_amount}
  def parse(input, currency) when is_binary(input) and is_binary(currency) do
    units = minor_units(currency)

    with [_match, major | rest] <- Regex.run(~r/\A(\d+)(?:[.,](\d+))?\z/, String.trim(input)),
         minor = List.first(rest, ""),
         true <- byte_size(minor) <= units,
         cents = String.to_integer(major <> String.pad_trailing(minor, units, "0")),
         true <- cents > 0 do
      {:ok, cents}
    else
      _invalid -> {:error, :invalid_amount}
    end
  end

  def parse(_input, _currency), do: {:error, :invalid_amount}

  @doc """
  `cents` as a plain decimal string in major units, without a symbol, for
  form inputs and their attributes (a prefilled price, a `max`).

      iex> Money.to_major_string(1250, "eur")
      "12.50"
      iex> Money.to_major_string(1000, "jpy")
      "1000"
  """
  @spec to_major_string(integer(), currency()) :: String.t()
  def to_major_string(cents, currency) when is_integer(cents) and is_binary(currency) do
    sign = if cents < 0, do: "-", else: ""
    sign <> major_digits(abs(cents), minor_units(currency), false)
  end

  @doc """
  `cents` formatted for people: the currency's symbol, or its upper-case
  code and a space where it has none, then the amount, with any minus sign
  in front of both.

  Options:

    * `:trim_zero_minor` - drop the decimals of a whole amount (`€10`
      rather than `€10.00`). Defaults to `false`.

  ## Examples

      iex> Money.format(1050, "eur")
      "€10.50"
      iex> Money.format(-1000, "gbp")
      "-£10.00"
      iex> Money.format(1000, "chf", trim_zero_minor: true)
      "CHF 10"
  """
  @spec format(integer(), currency(), keyword()) :: String.t()
  def format(cents, currency, opts \\ []) when is_integer(cents) and is_binary(currency) do
    code = String.downcase(currency)
    sign = if cents < 0, do: "-", else: ""

    digits =
      major_digits(abs(cents), minor_units(code), Keyword.get(opts, :trim_zero_minor, false))

    sign <> symbol(code) <> digits
  end

  @doc """
  The prefix `format/3` puts before an amount: the currency's symbol, or its
  upper-case code and a space where it has none. For a currency tag beside a
  form input.

      iex> Money.symbol("gbp")
      "£"
      iex> Money.symbol("chf")
      "CHF "
  """
  @spec symbol(currency()) :: String.t()
  def symbol(currency) when is_binary(currency) do
    code = String.downcase(currency)
    Map.get_lazy(@symbols, code, fn -> String.upcase(code) <> " " end)
  end

  defp major_digits(cents, 0, _trim?), do: Integer.to_string(cents)

  defp major_digits(cents, units, trim?) do
    scale = Integer.pow(10, units)
    major = Integer.to_string(div(cents, scale))

    case rem(cents, scale) do
      0 when trim? -> major
      minor -> major <> "." <> String.pad_leading(Integer.to_string(minor), units, "0")
    end
  end
end
