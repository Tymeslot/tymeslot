defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingCardTest do
  @moduledoc """
  Covers the sub panel the booking card stacks its guests, notes and answers
  in. The card itself is exercised through the Meetings page in
  `BookingsManagementTest`.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :bookings
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingCard

  test "sub_panel titles its content beside an icon" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <MeetingCard.sub_panel icon="hero-pencil-square" title="Meeting Notes">
        <p>Bring the slides</p>
      </MeetingCard.sub_panel>
      """)

    doc = Floki.parse_fragment!(html)

    assert doc |> Floki.find("h5") |> Floki.text() |> String.trim() == "Meeting Notes"
    assert [_icon] = Floki.find(doc, "svg")
    assert Floki.text(doc) =~ "Bring the slides"
  end

  test "sub_panel shows an aside in its header only when given one" do
    assigns = %{}

    with_aside =
      rendered_to_string(~H"""
      <MeetingCard.sub_panel icon="hero-user-group" title="Guests">
        <:aside>1 of 2 going</:aside>
        <ul></ul>
      </MeetingCard.sub_panel>
      """)

    without_aside =
      rendered_to_string(~H"""
      <MeetingCard.sub_panel icon="hero-user-group" title="Guests">
        <ul></ul>
      </MeetingCard.sub_panel>
      """)

    assert with_aside =~ "1 of 2 going"
    assert length(Floki.find(Floki.parse_fragment!(with_aside), "section > div > span")) == 1
    assert Floki.find(Floki.parse_fragment!(without_aside), "section > div > span") == []
  end
end
