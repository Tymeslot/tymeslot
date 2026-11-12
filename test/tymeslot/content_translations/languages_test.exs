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

  describe "offered/1 and content_locale/2" do
    test "a restricted profile offers its original then its translations" do
      profile =
        profile(content_locale: "en", translation_locales: ["de", "fr"], offer_all_locales: false)

      assert Languages.offered(profile) == ["en", "de", "fr"]
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

    test "refuses the original as a translation language", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_booking_languages(profile, %{
                 content_locale: "de",
                 translation_locales: ["de"]
               })

      assert %{translation_locales: [_message]} = errors_on(changeset)
    end

    test "refuses a language listed twice", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_booking_languages(profile, %{translation_locales: ["de", "de"]})

      assert %{translation_locales: [_message]} = errors_on(changeset)
    end
  end
end
