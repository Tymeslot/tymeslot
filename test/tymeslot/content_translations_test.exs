defmodule Tymeslot.ContentTranslationsTest do
  use ExUnit.Case, async: true

  @moduletag :i18n
  @moduletag :unit

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.ContentTranslations
  alias Tymeslot.CustomFields.{FieldDefinition, FieldOption}
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Venues.VenueSchema

  defp entry(text, original), do: %{"text" => text, "source" => :erlang.phash2(original)}

  defp meeting_type(translations \\ %{}) do
    %MeetingTypeSchema{
      name: "Intro call",
      description: "A first chat",
      custom_fields: [
        %FieldDefinition{
          id: "q1",
          type: "single_select",
          label: "Your role",
          help_text: nil,
          position: 0,
          options: [%FieldOption{key: "dev", label: "Developer"}]
        }
      ],
      locations: [
        %LocationOption{id: "l1", kind: :custom, label: "Café", details: "Ring twice"},
        %LocationOption{id: "l2", kind: :video, label: "Online"}
      ],
      translations: translations
    }
  end

  describe "localise/2" do
    test "replaces a meeting type's name, question, option and location texts" do
      type =
        meeting_type(%{
          "de" => %{
            "name" => entry("Erstgespräch", "Intro call"),
            "custom_fields/q1/label" => entry("Ihre Rolle", "Your role"),
            "custom_fields/q1/options/dev/label" => entry("Entwickler", "Developer"),
            "locations/l1/details" => entry("Zweimal klingeln", "Ring twice")
          }
        })

      localised = ContentTranslations.localise(type, "de")

      assert %MeetingTypeSchema{name: "Erstgespräch", description: "A first chat"} = localised
      # The address stays the original name's.
      assert localised.slug == "intro-call"

      assert [%FieldDefinition{label: "Ihre Rolle", options: [%{label: "Entwickler"}]}] =
               localised.custom_fields

      assert [%{label: "Café", details: "Zweimal klingeln"}, %{label: "Online"}] =
               localised.locations
    end

    test "falls back to the original for a blank translation and keeps a blank original blank" do
      type =
        meeting_type(%{
          "de" => %{
            "name" => %{"text" => "", "source" => 0},
            "custom_fields/q1/help_text" => entry("Hilfe", nil)
          }
        })

      localised = ContentTranslations.localise(type, "de")

      assert localised.name == "Intro call"
      assert hd(localised.custom_fields).help_text == nil
    end

    test "translates a profile's booking texts from the booking page it presents" do
      page = %BookingPageSchema{
        name: "Coaching",
        booking_heading: "Book coaching",
        translations: %{"de" => %{"booking_heading" => entry("Coaching buchen", "Book coaching")}}
      }

      profile = %ProfileSchema{
        booking_heading: "Book coaching",
        headline: "Coach",
        booking_page: page,
        meeting_types: [meeting_type(%{"de" => %{"name" => entry("Erstgespräch", "Intro call")}})],
        translations: %{
          "de" => %{
            "booking_heading" => entry("Profilüberschrift", "Book coaching"),
            "headline" => entry("Trainer", "Coach")
          }
        }
      }

      localised = ContentTranslations.localise(profile, "de")

      assert localised.booking_heading == "Coaching buchen"
      assert localised.booking_page.booking_heading == "Coaching buchen"
      assert localised.headline == "Trainer"
      assert [%{name: "Erstgespräch"}] = localised.meeting_types
    end

    test "leaves plain maps, untranslated structs and a nil locale untouched" do
      demo_persona = %{name: "Demo", booking_heading: "Hi", translations: %{"de" => %{}}}
      type = meeting_type(%{"de" => %{"name" => entry("Erstgespräch", "Intro call")}})

      assert ContentTranslations.localise(demo_persona, "de") == demo_persona
      assert ContentTranslations.localise(type, nil) == type
      assert ContentTranslations.localise(%URI{host: "x"}, "de") == %URI{host: "x"}
      assert ContentTranslations.localise([demo_persona], "de") == [demo_persona]
    end
  end

  describe "fields/1" do
    test "leaves out a location label still reading as its kind's stock default" do
      record = %{
        meeting_type()
        | locations: [
            %LocationOption{id: "l1", kind: :in_person, label: "In person"},
            %LocationOption{id: "l2", kind: :video, label: "Zoom with Anna"}
          ]
      }

      paths = record |> ContentTranslations.fields() |> Enum.map(& &1.path)

      refute "locations/l1/label" in paths
      assert "locations/l2/label" in paths
    end
  end

  describe "status/3" do
    test "is :not_needed for a blank original, :missing without a translation" do
      type = meeting_type()

      assert ContentTranslations.status(type, "custom_fields/q1/help_text", "de") == :not_needed
      assert ContentTranslations.status(type, "name", "de") == :missing
    end

    test "is :translated against the current original and :outdated once it changes" do
      type = meeting_type(%{"de" => %{"name" => entry("Erstgespräch", "Intro call")}})

      assert ContentTranslations.status(type, "name", "de") == :translated

      assert ContentTranslations.status(%{type | name: "Discovery call"}, "name", "de") ==
               :outdated
    end
  end

  describe "put/4" do
    test "stores a cleaned text against the current original" do
      translations =
        ContentTranslations.put(meeting_type(), "de", "name", "  Erst\x00gespräch \r\n")

      assert translations == %{"de" => %{"name" => entry("Erstgespräch", "Intro call")}}
    end

    test "a blank text deletes the path, and the locale once it is empty" do
      type =
        meeting_type(%{
          "de" => %{"name" => entry("Erstgespräch", "Intro call")},
          "fr" => %{"name" => entry("Premier appel", "Intro call")}
        })

      assert ContentTranslations.put(type, "de", "name", "   ") == %{
               "fr" => %{"name" => entry("Premier appel", "Intro call")}
             }
    end
  end

  describe "prune/2 and changeset/2" do
    test "prune drops the paths the record no longer has" do
      translations = %{
        "de" => %{
          "name" => entry("Erstgespräch", "Intro call"),
          "custom_fields/gone/label" => entry("Weg", "Gone")
        },
        "fr" => %{"locations/gone/label" => entry("Parti", "Gone")}
      }

      assert ContentTranslations.prune(translations, meeting_type()) == %{
               "de" => %{"name" => entry("Erstgespräch", "Intro call")}
             }
    end

    test "refuses a text over its original's cap, naming the path" do
      too_long = String.duplicate("a", VenueSchema.name_max_length() + 1)
      venue = %VenueSchema{name: "Office", translations: %{}}

      changeset =
        ContentTranslations.changeset(venue, %{"de" => %{"name" => entry(too_long, "Office")}})

      refute changeset.valid?
      assert [{:translations, {_message, opts}}] = changeset.errors
      assert opts[:path] == "name"
      assert opts[:count] == VenueSchema.name_max_length()
    end

    test "refuses an unsupported locale and accepts a valid map" do
      venue = %VenueSchema{name: "Office", translations: %{}}
      valid = %{"de" => %{"name" => entry("Büro", "Office")}}

      refute ContentTranslations.changeset(venue, %{"xx" => %{}}).valid?
      assert ContentTranslations.changeset(venue, valid).valid?
    end
  end
end
