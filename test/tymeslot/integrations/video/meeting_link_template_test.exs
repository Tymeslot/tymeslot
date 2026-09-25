defmodule Tymeslot.Integrations.Video.MeetingLinkTemplateTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :video
  @moduletag :unit

  alias Tymeslot.Integrations.Video

  describe "meeting_link_template_invalid?/1" do
    test "flags a custom link whose placeholder has single braces" do
      assert Video.meeting_link_template_invalid?(custom("https://meet.jit.si/{meeting_id}"))
    end

    test "flags a custom link whose placeholder is hidden behind percent escapes" do
      assert Video.meeting_link_template_invalid?(
               custom("https://meet.jit.si/%7B%7Bmeeting_id%7D%7D")
             )
    end

    test "accepts a custom link with a correctly written placeholder" do
      refute Video.meeting_link_template_invalid?(custom("https://meet.jit.si/{{meeting_id}}"))
    end

    test "accepts a static link that mentions meeting_id as a plain query parameter" do
      refute Video.meeting_link_template_invalid?(
               custom("https://meet.example.com/room?meeting_id=123")
             )
    end

    test "accepts a permanent Teams link whose decoded context carries braces" do
      refute Video.meeting_link_template_invalid?(
               custom(
                 "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjU4YTQ%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22a1b2c3d4%22%7d"
               )
             )
    end

    test "never flags a provider other than custom" do
      refute Video.meeting_link_template_invalid?(%{
               provider: "mirotalk",
               custom_meeting_url: "https://meet.jit.si/{meeting_id}"
             })
    end
  end

  defp custom(url), do: %{provider: "custom", custom_meeting_url: url}
end
