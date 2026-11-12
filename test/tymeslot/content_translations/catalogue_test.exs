defmodule Tymeslot.ContentTranslations.CatalogueTest do
  use Tymeslot.DataCase, async: true

  @moduletag :i18n

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.ContentTranslations.TranslationQueries
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Venues

  setup do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        booking_heading: "Book a call",
        headline: "Coach",
        translation_locales: ["de"]
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Intro call",
        description: nil,
        custom_fields: [
          %FieldDefinition{id: "q1", type: "short_text", label: "Company", position: 0}
        ]
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  describe "items/1" do
    test "groups the user's texts, with the profile split by card", %{
      user: user,
      profile: profile,
      meeting_type: meeting_type
    } do
      venue = insert(:venue, user: user, name: "Office")
      _archived = insert(:meeting_type, user: user, name: "Old", is_archived: true)
      _someone_elses = insert(:meeting_type, name: "Not mine")

      items = Catalogue.items(user.id)

      assert [%{kind: :profile, id: profile_id, fields: booking_fields}] = items.booking_texts
      assert profile_id == profile.id

      assert Enum.map(booking_fields, & &1.path) ==
               ~w(booking_heading booking_greeting booking_instruction)

      assert [%{kind: :profile, fields: [%{path: "headline"}, %{path: "bio"}]}] = items.intro

      assert [%{kind: :meeting_type, id: id, name: "Intro call", fields: fields}] =
               items.meeting_types

      assert id == meeting_type.id
      assert "custom_fields/q1/label" in Enum.map(fields, & &1.path)
      assert [%{kind: :venue, id: venue_id, name: "Office"}] = items.venues
      assert venue_id == venue.id
    end
  end

  describe "get/2" do
    test "reads the user's entity as stored, with its translations", %{
      user: user,
      meeting_type: meeting_type
    } do
      {:ok, _saved} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      assert {:ok, %{kind: :meeting_type, id: id, record: record}} =
               Catalogue.get(user.id, {:meeting_type, to_string(meeting_type.id)})

      assert id == meeting_type.id
      assert ContentTranslations.translation(record, "de", "name") == "Erstgespräch"
    end

    test "refuses another user's entity", %{meeting_type: meeting_type, profile: profile} do
      other = insert(:user)
      insert(:profile, user: other)

      assert {:error, :not_found} = Catalogue.get(other.id, {:meeting_type, meeting_type.id})
      assert {:error, :not_found} = Catalogue.get(other.id, {:profile, profile.id})
    end
  end

  describe "save/4 and progress/2" do
    test "saves translations, which progress counts and a form save keeps", %{
      user: user,
      meeting_type: meeting_type
    } do
      progress = fn -> user.id |> Catalogue.items() |> Catalogue.progress(["de", "fr"]) end

      assert %{"de" => %{total: total, translated: 0, missing: total} = untouched} = progress.()

      assert {:ok, %{record: saved}} =
               Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
                 "name" => "Erstgespräch",
                 "custom_fields/q1/label" => "Firma",
                 "no/such/path" => "ignored"
               })

      assert ContentTranslations.text(saved, "custom_fields/q1/label", "de") == "Firma"
      assert Map.keys(saved.translations["de"]) == ["custom_fields/q1/label", "name"]
      # Each language is counted on its own, from the one read of the items.
      assert %{"de" => %{translated: 2, missing: missing}, "fr" => ^untouched} = progress.()
      assert missing == total - 2

      # The meeting type form never casts the translations, so saving it
      # afterwards keeps them; renaming the type marks the name outdated.
      {:ok, _updated} = MeetingTypes.update_meeting_type(saved, %{"name" => "Discovery call"})
      reloaded = Repo.get!(MeetingTypeSchema, meeting_type.id)

      assert reloaded.translations == saved.translations
      assert ContentTranslations.status(reloaded, "name", "de") == :outdated
      assert %{"de" => %{outdated: 1, translated: 1}} = progress.()
    end

    test "a blank text deletes the translation", %{user: user, meeting_type: meeting_type} do
      {:ok, _entity} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      assert {:ok, %{record: saved}} =
               Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => " "})

      assert saved.translations == %{}
    end

    test "saves profile and venue texts", %{user: user, profile: profile} do
      {:ok, venue} = Venues.create_venue(user.id, %{name: "Office"})

      assert {:ok, _entity} =
               Catalogue.save(user.id, {:profile, profile.id}, "de", %{"headline" => "Trainerin"})

      assert {:ok, _entity} =
               Catalogue.save(user.id, {:venue, to_string(venue.id)}, "de", %{"name" => "Büro"})

      {:ok, reloaded} = Profiles.get_profile_by_user_id(user.id)
      assert ContentTranslations.text(reloaded, "headline", "de") == "Trainerin"
    end

    test "refuses another user's entity", %{meeting_type: meeting_type, profile: profile} do
      other = insert(:user)
      insert(:profile, user: other, translation_locales: ["de"])

      assert {:error, :not_found} =
               Catalogue.save(other.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "X"})

      assert {:error, :not_found} =
               Catalogue.save(other.id, {:profile, profile.id}, "de", %{"headline" => "X"})
    end

    test "refuses a language that is not a translation language", %{
      user: user,
      meeting_type: meeting_type
    } do
      assert {:error, %Changeset{} = changeset} =
               Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "fr", %{
                 "name" => "Appel"
               })

      assert [{:translations, {"is not a translation language", _opts}}] = changeset.errors
    end

    test "drops a stored language no longer supported rather than refusing the save", %{
      user: user,
      meeting_type: meeting_type
    } do
      retired = %{"name" => %{"text" => "Retired", "source" => :erlang.phash2("Intro call")}}

      meeting_type
      |> Changeset.change(translations: %{"xx" => retired})
      |> Repo.update!()

      assert {:ok, %{record: saved}} =
               Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
                 "name" => "Erstgespräch"
               })

      assert Map.keys(saved.translations) == ["de"]
      assert ContentTranslations.text(saved, "name", "de") == "Erstgespräch"
    end

    test "refuses a text over its cap", %{user: user, meeting_type: meeting_type} do
      too_long = String.duplicate("a", 121)

      assert {:error, changeset} =
               Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
                 "custom_fields/q1/label" => too_long
               })

      assert [{:translations, {_message, opts}}] = changeset.errors
      assert opts[:path] == "custom_fields/q1/label"
    end
  end

  describe "confirm/4" do
    setup %{user: user, meeting_type: meeting_type} do
      {:ok, _saved} =
        Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{
          "name" => "Erstgespräch"
        })

      {:ok, _renamed} =
        MeetingTypes.update_meeting_type(Repo.get!(MeetingTypeSchema, meeting_type.id), %{
          "name" => "Discovery call"
        })

      :ok
    end

    test "marks an outdated translation as still correct, without changing its text", %{
      user: user,
      meeting_type: meeting_type
    } do
      progress = fn -> user.id |> Catalogue.items() |> Catalogue.progress(["de"]) end
      assert %{"de" => %{outdated: 1}} = progress.()

      assert {:ok, %{record: confirmed}} =
               Catalogue.confirm(user.id, {:meeting_type, meeting_type.id}, "de", ["name"])

      reloaded = Repo.get!(MeetingTypeSchema, meeting_type.id)
      assert reloaded.translations == confirmed.translations
      assert ContentTranslations.status(reloaded, "name", "de") == :translated
      assert ContentTranslations.translation(reloaded, "de", "name") == "Erstgespräch"
      assert ContentTranslations.localise(reloaded, "de").name == "Erstgespräch"
      assert %{"de" => %{outdated: 0, translated: 1}} = progress.()
    end

    test "is not found for another user's entity", %{meeting_type: meeting_type} do
      other = insert(:user)
      insert(:profile, user: other, translation_locales: ["de"])

      assert {:error, :not_found} =
               Catalogue.confirm(other.id, {:meeting_type, meeting_type.id}, "de", ["name"])

      reloaded = Repo.get!(MeetingTypeSchema, meeting_type.id)
      assert ContentTranslations.status(reloaded, "name", "de") == :outdated
    end

    test "refuses a language that is not a translation language", %{
      user: user,
      meeting_type: meeting_type
    } do
      assert {:error, %Changeset{} = changeset} =
               Catalogue.confirm(user.id, {:meeting_type, meeting_type.id}, "fr", ["name"])

      assert [{:translations, {_message, opts}}] = changeset.errors
      assert opts[:locale] == "fr"
    end
  end

  describe "TranslationQueries.lock/1" do
    test "re-reads the translations a stale record was read without", %{
      meeting_type: meeting_type
    } do
      committed = %{"de" => %{"name" => %{"text" => "Erstgespräch", "source" => 1}}}

      meeting_type
      |> Changeset.change(translations: committed)
      |> Repo.update!()

      assert {:ok, {:ok, locked}} =
               Repo.transaction(fn -> TranslationQueries.lock(meeting_type) end)

      assert locked.translations == committed
      assert locked.name == meeting_type.name
    end

    # A translation is stamped against the original it is saved beside, so
    # the originals are the locked row's, not those of the caller's read.
    test "re-reads the originals a stale record was read with", %{meeting_type: meeting_type} do
      meeting_type
      |> Changeset.change(name: "Discovery call")
      |> Repo.update!()

      assert {:ok, {:ok, locked}} =
               Repo.transaction(fn -> TranslationQueries.lock(meeting_type) end)

      assert locked.name == "Discovery call"
    end

    test "is not found for a row that has gone", %{meeting_type: meeting_type} do
      Repo.delete!(meeting_type)

      assert {:ok, {:error, :not_found}} =
               Repo.transaction(fn -> TranslationQueries.lock(meeting_type) end)
    end
  end
end
