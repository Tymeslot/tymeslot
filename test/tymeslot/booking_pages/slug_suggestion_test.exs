defmodule Tymeslot.BookingPages.SlugSuggestionTest do
  use ExUnit.Case, async: true

  @moduletag :profiles

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.BookingPages.SlugSuggestion

  doctest SlugSuggestion, import: true

  describe "from_name/1" do
    test "spells out the letters of the app's Latin-script languages" do
      assert SlugSuggestion.from_name("Prüfung für Gäste") == "pruefung-fuer-gaeste"
      assert SlugSuggestion.from_name("Straße") == "strasse"
      assert SlugSuggestion.from_name("Café crème") == "cafe-creme"
      assert SlugSuggestion.from_name("Łódź") == "lodz"
      assert SlugSuggestion.from_name("Přednáška") == "prednaska"
      assert SlugSuggestion.from_name("Reunião") == "reuniao"
      assert SlugSuggestion.from_name("Año nuevo") == "ano-nuevo"
    end

    test "transliterates Cyrillic" do
      assert SlugSuggestion.from_name("Консультація") == "konsultatsiia"
      assert SlugSuggestion.from_name("Їжак і ґанок") == "izhak-i-ganok"
      assert SlugSuggestion.from_name("Щоденник") == "shchodennyk"
      assert SlugSuggestion.from_name("Съёмка") == "semka"
    end

    test "cuts a long name to 30 characters at a hyphen" do
      slug = SlugSuggestion.from_name("Strategy session for small business owners")

      assert slug == "strategy-session-for-small"
      assert String.length(slug) <= 30
    end

    test "cuts a single word longer than the limit where it must" do
      assert SlugSuggestion.from_name(String.duplicate("a", 40)) == String.duplicate("a", 30)
    end

    test "pads a name too short to be an address" do
      assert SlugSuggestion.from_name("AI") == "ai-page"
    end

    test "moves a reserved word aside" do
      assert SlugSuggestion.from_name("Book") == "book-page"
      assert SlugSuggestion.from_name("Thank you") == "thank-you-page"
    end

    test "falls back to a word when nothing of the name can be spelt" do
      assert SlugSuggestion.from_name("日本語") == "page"
      assert SlugSuggestion.from_name("🎉🎉") == "page"
    end

    test "is empty while the name is blank" do
      assert SlugSuggestion.from_name("   ") == ""
      assert SlugSuggestion.from_name(nil) == ""
    end

    test "every suggestion for a non-blank name passes the address rules" do
      names = [
        "AI",
        "Book",
        "日本語",
        "Консультація для батьків і вчителів у школі",
        "Strategy session for small business owners",
        String.duplicate("x", 50),
        "-- Workshop --",
        "1:1"
      ]

      invalid =
        Enum.reject(names, fn name ->
          changeset =
            BookingPageSchema.details_changeset(%BookingPageSchema{}, %{
              "name" => name,
              "slug" => SlugSuggestion.from_name(name)
            })

          changeset.errors[:slug] == nil
        end)

      assert invalid == []
    end
  end
end
