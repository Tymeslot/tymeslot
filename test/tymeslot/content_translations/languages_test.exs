defmodule Tymeslot.ContentTranslations.LanguagesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :i18n

  import Tymeslot.Factory

  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.Locales
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  defp profile(attrs), do: struct(%ProfileSchema{}, attrs)

  describe "resolve/2" do
    test "picks the first candidate a restricted profile offers" do
      profile =
        profile(content_locale: "en", translation_locales: ["de"], offer_all_locales: false)

      assert Languages.resolve(profile, ["fr", "de", "en"]) == "de"
    end

    test "falls back to the original when no candidate is offered" do
      profile =
        profile(content_locale: "it", translation_locales: ["de"], offer_all_locales: false)

      assert Languages.resolve(profile, ["fr", "xx"]) == "it"
      assert Languages.resolve(profile, []) == "it"
    end

    test "takes any acceptable candidate while every language is offered" do
      profile = profile(content_locale: "en", translation_locales: [], offer_all_locales: true)

      assert Languages.resolve(profile, ["xx", "fr"]) == "fr"
    end

    test "a demo persona (a plain map) offers everything in the fallback language" do
      assert Languages.offered(%{username: "demo"}) == Locales.supported_codes()
      assert Languages.original(%{username: "demo"}) == Locales.booking_default_locale()
    end
  end

  describe "visitor_locale/2" do
    setup do
      %{
        profile:
          profile(
            content_locale: "en",
            translation_locales: ["de", "fr"],
            offer_all_locales: false
          )
      }
    end

    test "the visitor's pick wins over the booked language", %{profile: profile} do
      assert Languages.visitor_locale(profile, picked: "fr", booked: "de", browser: []) == "fr"
    end

    test "the visitor's pick wins over the browser", %{profile: profile} do
      assert Languages.visitor_locale(profile, picked: "fr", browser: ["de"]) == "fr"
    end

    test "the booked language wins over the browser when nothing was picked", %{
      profile: profile
    } do
      assert Languages.visitor_locale(profile, picked: nil, booked: "de", browser: ["fr"]) ==
               "de"
    end

    test "a pick not offered gives the original, not the booked or browser language", %{
      profile: profile
    } do
      assert Languages.visitor_locale(profile, picked: "it", booked: "de", browser: ["fr"]) ==
               "en"

      assert Languages.stale_pick?(profile, "it")
    end

    test "a booked language not offered falls through to the browser", %{profile: profile} do
      assert Languages.visitor_locale(profile, booked: "it", browser: ["xx", "fr"]) == "fr"
      refute Languages.stale_pick?(profile, nil)
    end

    test "nothing offered among the candidates gives the original", %{profile: profile} do
      assert Languages.visitor_locale(profile, booked: "it", browser: ["pl"]) == "en"
    end

    test "every pick is offered while every language is", %{profile: profile} do
      profile = %{profile | offer_all_locales: true}

      assert Languages.visitor_locale(profile, picked: "it", booked: "de") == "it"
      refute Languages.stale_pick?(profile, "it")
    end
  end

  describe "offered/1 and content_locale/2" do
    test "a restricted profile offers its original then its translations" do
      profile =
        profile(content_locale: "en", translation_locales: ["de", "fr"], offer_all_locales: false)

      assert Languages.offered(profile) == ["en", "de", "fr"]
    end

    test "translatable/1 is every offered language but the original" do
      all =
        profile(content_locale: "en", translation_locales: ["en", "de"], offer_all_locales: true)

      assert Languages.translatable(all) == Locales.supported_codes() -- ["en"]

      own =
        profile(content_locale: "en", translation_locales: ["en", "de"], offer_all_locales: false)

      assert Languages.translatable(own) == ["de"]
    end

    test "only a translation language shows translated texts" do
      profile =
        profile(content_locale: "en", translation_locales: ["de"], offer_all_locales: true)

      assert Languages.content_locale(profile, "de") == "de"
      assert Languages.content_locale(profile, "fr") == nil
      assert Languages.content_locale(profile, "en") == nil
    end
  end

  describe "Profiles.update_booking_languages/2" do
    setup do
      %{profile: insert(:profile)}
    end

    test "saves the languages", %{profile: profile} do
      assert {:ok, saved} =
               Profiles.update_booking_languages(profile, %{
                 content_locale: "en",
                 translation_locales: ["de", "fr"],
                 offer_all_locales: false
               })

      assert %{content_locale: "en", translation_locales: ["de", "fr"], offer_all_locales: false} =
               saved
    end

    test "saves the original the texts read as, so it no longer follows the fallback", %{
      profile: profile
    } do
      assert profile.content_locale == nil

      assert {:ok, saved} =
               Profiles.update_booking_languages(profile, %{translation_locales: ["de"]})

      assert saved.content_locale == Locales.booking_default_locale()
      assert Repo.get!(ProfileSchema, profile.id).content_locale == saved.content_locale
    end

    test "the fallback can be ticked while the original is unset, and stays the original", %{
      profile: profile
    } do
      fallback = Locales.booking_default_locale()

      assert {:ok, saved} =
               Profiles.update_booking_languages(profile, %{translation_locales: [fallback]})

      assert saved.content_locale == fallback
      assert Languages.chosen(saved) == [fallback]
      assert Languages.translation_locales(saved) == []
    end

    test "a new profile offers every language with no translations", %{profile: profile} do
      reloaded = Repo.get!(ProfileSchema, profile.id)

      assert %{translation_locales: [], offer_all_locales: true, translations: %{}} = reloaded
    end

    test "refuses an unsupported code", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_booking_languages(profile, %{translation_locales: ["xx"]})

      assert %{translation_locales: [_message]} = errors_on(changeset)

      assert {:error, changeset} =
               Profiles.update_booking_languages(profile, %{content_locale: "xx"})

      assert %{content_locale: [_message]} = errors_on(changeset)
    end

    test "keeps the original ticked, but does not translate into it", %{profile: profile} do
      assert {:ok, saved} =
               Profiles.update_booking_languages(profile, %{
                 content_locale: "de",
                 translation_locales: ["de", "fr"]
               })

      assert saved.translation_locales == ["de", "fr"]
      assert Languages.chosen(saved) == ["de", "fr"]
      assert Languages.translation_locales(saved) == ["fr"]
      assert Languages.content_locale(saved, "de") == nil
    end

    test "refuses a language listed twice", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_booking_languages(profile, %{translation_locales: ["de", "de"]})

      assert %{translation_locales: [_message]} = errors_on(changeset)
    end
  end
end
