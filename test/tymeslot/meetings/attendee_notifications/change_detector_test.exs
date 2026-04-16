defmodule Tymeslot.Meetings.AttendeeNotifications.ChangeDetectorTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Tymeslot.Meetings.AttendeeNotifications.{ChangeDetector, ChangeSummary}

  defp event(attrs \\ %{}) do
    Map.merge(
      %{
        title: "t",
        starts_at: ~U[2026-01-01 10:00:00Z],
        ends_at: ~U[2026-01-01 11:00:00Z],
        location: "",
        description: "",
        video_link: nil,
        attendees: []
      },
      attrs
    )
  end

  test "no change → empty summary" do
    s = ChangeDetector.diff(event(), event(), current_sequence: 0)
    refute ChangeSummary.any_changes?(s)
  end

  test "title change is notifiable" do
    s = ChangeDetector.diff(event(), event(%{title: "new"}), current_sequence: 0)
    assert :title in s.changed_fields
  end

  test "description whitespace difference is not a change" do
    s =
      ChangeDetector.diff(
        event(%{description: "hello"}),
        event(%{description: "  hello  "}),
        current_sequence: 0
      )

    refute ChangeSummary.any_changes?(s)
  end

  test "description HTML reformat is not a change" do
    a = event(%{description: "<p>hello <b>world</b></p>"})
    b = event(%{description: "<div>hello world</div>"})
    s = ChangeDetector.diff(a, b, current_sequence: 0)
    refute ChangeSummary.any_changes?(s)
  end

  test "starts_at in different tz but same instant is not a change" do
    {:ok, paris} = DateTime.new(~D[2026-01-01], ~T[11:00:00], "Europe/Paris")
    s = ChangeDetector.diff(event(), event(%{starts_at: paris}), current_sequence: 0)
    refute ChangeSummary.any_changes?(s)
  end

  test "video link change is notifiable" do
    s =
      ChangeDetector.diff(
        event(%{video_link: nil}),
        event(%{video_link: "https://x"}),
        current_sequence: 0
      )

    assert :video_link in s.changed_fields
  end

  test "attendee added / removed / retained are split correctly" do
    old = event(%{attendees: [%{email: "a@x"}, %{email: "b@x"}]})
    new = event(%{attendees: [%{email: "B@X"}, %{email: "c@x"}]})
    s = ChangeDetector.diff(old, new, current_sequence: 2)
    assert Enum.map(s.added_attendees, & &1.email) == ["c@x"]
    assert Enum.map(s.removed_attendees, & &1.email) == ["a@x"]
    assert Enum.map(s.retained_attendees, & &1.email) == ["b@x"]
  end

  test "next_sequence bumps by 1 when field changes" do
    s = ChangeDetector.diff(event(), event(%{title: "new"}), current_sequence: 4)
    assert s.next_sequence == 5
  end

  test "next_sequence bumps by 1 when only attendees changed" do
    old = event(%{attendees: [%{email: "a@x"}]})
    new = event(%{attendees: [%{email: "a@x"}, %{email: "b@x"}]})
    s = ChangeDetector.diff(old, new, current_sequence: 4)
    assert s.next_sequence == 5
  end
end
