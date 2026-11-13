defmodule Tymeslot.MeetingPayments.Money do
  @moduledoc """
  Amounts of money as integer minor units (cents), the way Stripe counts
  them, and the one place they are parsed from and formatted for people.

  A currency's minor units follow Stripe: most currencies have two decimal
  places, the zero-decimal ones (`jpy`, `krw`, ...) are counted in whole
  units, and the three-decimal ones (`bhd`, `kwd`, ...) in thousandths.
  Currency codes are lower-case ISO 4217, as Stripe sends them; any case is
  accepted.

  Formatting follows the reader's locale, which defaults to the current
  Gettext locale, so an amount interpolated into a translated sentence reads
  the way the sentence's language writes money: `€1,234.50` in English,
  `1.234,50 €` in German, `1 234,50 €` in Polish. The sign always leads
  (`-€10.00`, `-10,00 €`).
  """

  alias TymeslotWeb.Helpers.LocaleFormat

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

  # The locales that write the symbol after the amount ("45,00 €"). Spanish
  # follows the RAE here, though Latin American shops often put "$" first.
  @symbol_after_locales ~w(de fr it cs pl uk es)

  # The locales that lead with the symbol but set it off by a space, as
  # Brazilian Portuguese does ("R$ 45,00", "€ 45,00").
  @spaced_symbol_before_locales ~w(pt)

  # Symbols a locale writes differently from `@symbols`, matching CLDR and
  # each locale's catalogues: Portuguese and Spanish mark the US dollar as
  # "US$" ("US$ 10", "10 US$"), Polish writes the code ("10 USD").
  @locale_symbols %{
    "es" => %{"usd" => "US$"},
    "pl" => %{"usd" => "USD"},
    "pt" => %{"usd" => "US$"}
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
  `cents` formatted for people reading `:locale`: the currency's symbol, or
  its upper-case code where it has none, and the amount, grouped and
  separated by the locale's conventions, with any minus sign in front of both.

  The symbol leads in English, flush against a sign (`€10.50`) and a space
  from a code (`CHF 10.00`), and in Brazilian Portuguese, a space from either
  (`€ 10,50`, `US$ 10,50`). It trails in the locales that write it after the amount
  (`10,50 €`, `10,00 CHF`). A space beside a sign is non-breaking, so the two
  never wrap apart.

  Options:

    * `:locale` - the locale to format for. Defaults to the current
      `TymeslotWeb.Gettext` locale; an unknown locale is formatted as English.
    * `:trim_zero_minor` - drop the decimals of a whole amount (`€10`
      rather than `€10.00`). Defaults to `false`.

  ## Examples

      iex> Money.format(1050, "eur", locale: "en")
      "€10.50"
      iex> Money.format(-123_450, "eur", locale: "de")
      "-1.234,50\u00A0€"
      iex> Money.format(1000, "chf", locale: "en", trim_zero_minor: true)
      "CHF 10"
  """
  @spec format(integer(), currency(), keyword()) :: String.t()
  def format(cents, currency, opts \\ []) when is_integer(cents) and is_binary(currency) do
    code = String.downcase(currency)
    locale = Keyword.get_lazy(opts, :locale, fn -> Gettext.get_locale(TymeslotWeb.Gettext) end)
    sign = if cents < 0, do: "-", else: ""

    number =
      abs(cents)
      |> major_digits(minor_units(code), Keyword.get(opts, :trim_zero_minor, false))
      |> localise_number(locale)

    sign <> place_symbol(number, String.trim(symbol(code, locale: locale)), locale)
  end

  @doc """
  Whether `locale` writes the currency symbol after the amount, so a currency
  tag beside a price input can sit on the same side as the formatted amount.
  """
  @spec symbol_after?(String.t()) :: boolean()
  def symbol_after?(locale), do: locale in @symbol_after_locales

  @doc """
  The prefix `format/3` puts before an amount: the currency's symbol as
  `:locale` writes it, or its upper-case code and a space where it has none.
  For a currency tag beside a form input. `:locale` defaults to the current
  `TymeslotWeb.Gettext` locale.

      iex> Money.symbol("gbp")
      "£"
      iex> Money.symbol("chf")
      "CHF "
      iex> Money.symbol("usd", locale: "pt")
      "US$"
  """
  @spec symbol(currency(), keyword()) :: String.t()
  def symbol(currency, opts \\ []) when is_binary(currency) do
    code = String.downcase(currency)
    locale = Keyword.get_lazy(opts, :locale, fn -> Gettext.get_locale(TymeslotWeb.Gettext) end)

    @locale_symbols
    |> Map.get(locale, %{})
    |> Map.get_lazy(code, fn ->
      Map.get_lazy(@symbols, code, fn -> String.upcase(code) <> " " end)
    end)
  end

  defp localise_number(digits, locale) do
    case String.split(digits, ".") do
      [major] -> group(major, locale)
      [major, minor] -> group(major, locale) <> LocaleFormat.decimal_separator(locale) <> minor
    end
  end

  defp group(major, locale),
    do: major |> String.to_integer() |> LocaleFormat.format_integer(locale)

  defp place_symbol(number, symbol, locale) do
    cond do
      symbol_after?(locale) -> number <> "\u00A0" <> symbol
      locale in @spaced_symbol_before_locales -> symbol <> "\u00A0" <> number
      # A letter code such as "CHF" needs a space before the digits, where a
      # sign such as "€" sits flush against them.
      String.match?(symbol, ~r/^\p{L}+$/u) -> symbol <> " " <> number
      true -> symbol <> number
    end
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
