defmodule Tymeslot.ContentTranslations.AttendeeTextsTest do
  use ExUnit.Case, async: true

  @moduletag :i18n
  @moduletag :unit

  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileSchema

  @profile %ProfileSchema{content_locale: "en", translation_locales: ["de"]}

  describe "text/3" do
    test "reads a text the copy holds as nil, or leaves out, as the meeting's own" do
      meeting = %{
        meeting_type: "Intro call",
        description: "A first chat",
        location: "Studio",
        attendee_texts: %{"de" => %{"meeting_type" => nil, "location" => "Atelier"}}
      }

      assert AttendeeTexts.text(meeting, :meeting_type, "de") == "Intro call"
      assert AttendeeTexts.text(meeting, :description, "de") == "A first chat"
      assert AttendeeTexts.text(meeting, :location, "de") == "Atelier"
      assert AttendeeTexts.text(meeting, :location, "fr") == "Studio"
    end
  end

  describe "build/4" do
    test "stores no copy for a type without a description when nothing is translated" do
      meeting_type = %MeetingTypeSchema{
        name: "Intro call",
        description: nil,
        translations: %{}
      }

      attrs = %{
        meeting_type: "Intro call",
        description: nil,
        location: nil,
        custom_fields_snapshot: [],
        attendee_locale: "de"
      }

      assert AttendeeTexts.build(meeting_type, @profile, attrs, %{}) == nil
      assert AttendeeTexts.build(meeting_type, @profile, %{attrs | description: ""}, %{}) == nil
    end
  end
end
