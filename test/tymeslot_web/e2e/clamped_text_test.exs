defmodule TymeslotWeb.E2E.ClampedTextTest do
  @moduledoc """
  A meeting type's description on the booking page's schedule step is cut to
  a few lines, and Show more appears only when the cut actually hides text
  (`ClampedText`, in `assets/js/hooks/clamped_text.js`): whether it does
  depends on the width the page is drawn at, which only the browser knows.
  Show more opens the whole text and Show less folds it again.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :bookings

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles

  @block "[data-testid='meeting-type-description']"
  @toggle "#{@block} button[aria-controls]"

  @long_description String.duplicate(
                      "We talk through what you need, what has worked so far and what has not. ",
                      6
                    )

  # About 180 characters: within three lines of a desktop card (some 600px
  # wide), about five on a 320px phone.
  @medium_description "A short first call to get to know each other, " <>
                        "agree what you need and plan the next steps together, " <>
                        "with time at the end for any questions you bring along."

  feature "Show more appears only for a description the cut hides, and opens and folds it",
          %{session: session} do
    %{username: username, user_id: user_id} = host()

    short = meeting_type(user_id, "Hello", "A quick hello.")
    long = meeting_type(user_id, "Deep dive", @long_description)

    # A description that fits shows whole, with no toggle.
    session
    |> visit("/#{username}/#{Slugs.to_slug(short)}")
    |> wait_for_live()
    |> assert_has(css(@block, text: "A quick hello."))
    |> assert_has(css("#{@block}:not([data-overflowing])"))
    |> assert_has(css(@toggle, visible: false))

    # A long one is cut, and offers the rest.
    session =
      session
      |> visit("/#{username}/#{Slugs.to_slug(long)}")
      |> wait_for_live()
      |> assert_has(css("#{@block}[data-overflowing]"))
      |> assert_has(css("#{@toggle}[aria-expanded='false']", text: "Show more"))

    assert cut?(session)

    session =
      session
      |> click(css(@toggle))
      |> assert_has(css("#{@toggle}[aria-expanded='true']", text: "Show less"))

    refute cut?(session)

    session =
      session
      |> click(css(@toggle))
      |> assert_has(css("#{@toggle}[aria-expanded='false']", text: "Show more"))

    assert cut?(session)
  end

  feature "narrowing the page to a phone offers Show more for text that fit before",
          %{session: session} do
    %{username: username, user_id: user_id} = host()
    medium = meeting_type(user_id, "Intro", @medium_description)

    session =
      session
      |> resize_window(1280, 900)
      |> visit("/#{username}/#{Slugs.to_slug(medium)}")
      |> wait_for_live()
      |> assert_has(css("#{@block}:not([data-overflowing])"))
      |> assert_has(css(@toggle, visible: false))

    refute cut?(session)

    session =
      session
      |> resize_to_mobile()
      |> assert_has(css("#{@block}[data-overflowing]"))
      |> assert_has(css(@toggle, text: "Show more"))

    assert cut?(session)
  end

  defp host do
    user = create_onboarded_user()
    insert(:calendar_integration, user: user)
    %{username: Profiles.get_profile(user.id).username, user_id: user.id}
  end

  defp meeting_type(user_id, name, description) do
    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user_id,
        name: name,
        description: description,
        duration_minutes: 30,
        is_active: true
      })

    meeting_type
  end

  # Whether the description's text runs past the box it is drawn in.
  defp cut?(session) do
    evaluate_script(session, """
    const text = document.querySelector("#{@block} [data-clamped-text]");
    return text.scrollHeight > text.clientHeight + 1;
    """)
  end
end
