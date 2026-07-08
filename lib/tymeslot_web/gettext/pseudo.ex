defmodule TymeslotWeb.Gettext.Pseudo do
  @moduledoc """
  Pseudo-localisation transform for the `"pseudo"` development locale.

  Pseudo-localisation is a coverage-testing technique, not a real language.
  Every string that genuinely flows through Gettext is rewritten into an
  accented, bracketed, padded look-alike:

      "Save changes"  ->  "⟦Šávé çħáñgéš····⟧"

  This surfaces two classes of bug at a glance:

  1. **Un-wrapped strings.** Any user-facing text that is *not* bracketed on a
     pseudo-locale page never went through Gettext — it is a hard-coded literal
     that would ship untranslated. The `⟦` marker is what the automated
     coverage crawl keys on.

  2. **Truncation / overflow.** The accented characters plus the ~30 %
     `·`-padding widen every label, exposing fixed-width buttons, clipped
     table cells, and layouts that only ever saw English.

  The transform is applied to the *resolved English string*, not the raw
  msgid — see `TymeslotWeb.Gettext` — so key-based catalogs (e.g. the booking
  domain, whose msgids are semantic keys like `"meeting_confirmed"`) pseudo-ise
  the English text a user would actually see, not the developer key.

  Activation is gated behind `Tymeslot.Locales.pseudo_enabled?/0`, which is
  `false` everywhere except dev. It can never render in production.
  """

  # Latin letter → accented look-alike. A module-attribute lookup table built
  # once at compile time from two aligned alphabets (static-lookup-table idiom).
  @plain ~w(a b c d e f g h i j k l m n o p q r s t u v w x y z
            A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)

  @accented ~w(á ƀ ç ð é ƒ ǧ ħ í ĵ ķ ł ɱ ñ ó þ ɋ ř š ŧ ú ṽ ŵ ẋ ý ž
               Á Ɓ Ç Ð É Ƒ Ǧ Ħ Í Ĵ Ķ Ł Ṁ Ñ Ó Þ Ɋ Ř Š Ŧ Ú Ṽ Ŵ Ẋ Ý Ž)

  @accent_map @plain |> Enum.zip(@accented) |> Map.new()

  @open "⟦"
  @close "⟧"
  @pad_char "·"
  @pad_ratio 0.3

  @doc """
  Rewrites `string` into its accented, bracketed, padded pseudo form.

  Strings with no Latin letters (pure punctuation, arrows, numbers) are returned
  unchanged — there is nothing to pseudo-localise and nothing the coverage crawl
  would flag either way.
  """
  @spec transform(String.t()) :: String.t()
  def transform(string) when is_binary(string) do
    if String.match?(string, ~r/[A-Za-z]/) do
      accented = accent(string)
      @open <> accented <> padding(accented) <> @close
    else
      string
    end
  end

  defp accent(string) do
    string
    |> String.codepoints()
    |> Enum.map_join("", &Map.get(@accent_map, &1, &1))
  end

  defp padding(accented) do
    length = accented |> String.length() |> Kernel.*(@pad_ratio) |> round() |> max(1)
    String.duplicate(@pad_char, length)
  end
end
