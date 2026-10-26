defmodule TymeslotWeb.E2E.EmbedConfirmationLayoutTest do
  @moduledoc """
  Guards the embedded Rhythm confirmation ticket, whose entries share flex
  lines and wrap as the card narrows.

  An in-person type with no venue shows the "address arranged after booking"
  note in the location entry. That entry used to stay beside Date, Time and
  Host however little width was left, and the ticket body, which clips its
  overflow, cut off its label.

  `iframe_embed.js` marks `<html>` with `data-embedded` inside the iframe;
  setting the attribute on a top-level page exercises the same embedded rules
  without the embed token and parent-origin handshake, as
  `EmbedSizesMatrixTest` does for the other steps.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Wallaby.Element

  @moduletag :e2e
  @moduletag :scheduling

  @height 800

  # Sub-pixel rounding in the WebDriver bridge; see EmbedSizesMatrixTest.
  @overflow_tolerance 1

  feature "embedded rhythm confirmation keeps an arranged location entry unclipped",
          %{session: session} do
    {profile, slug} = create_user_with_arranged_location()

    session =
      session
      |> resize_window(1000, @height)
      |> visit("/#{profile.username}/#{slug}?theme=2")
      |> wait_for_live()
      |> pick_first(css("[data-testid='calendar-day']:not([disabled])", count: :any))
      |> assert_has(css("[data-testid='time-slot']", minimum: 1))
      |> pick_first(css("[data-testid='time-slot']", count: :any))
      |> click_next_step()
      |> submit_booking_form()
      |> assert_has(css("[data-testid='location-arranged-note']"))
      |> execute_script("document.documentElement.setAttribute('data-embedded', '');")

    for width <- [640, 800, 1000], reduce: session do
      acc ->
        acc
        |> resize_window(width, @height)
        |> assert_location_entry_unclipped("rhythm embedded confirmation width=#{width}px")
    end
  end

  defp create_user_with_arranged_location do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Embedded Confirmation Visit",
        duration_minutes: 30,
        is_active: true,
        locations: [in_person_location()]
      )

    {profile, Slugs.to_slug(meeting_type)}
  end

  defp pick_first(session, query) do
    session
    |> find(query)
    |> List.first()
    |> Element.click()

    session
  end

  # An instant scroll keeps chromedriver's click on Next from landing before a
  # smooth scroll arrives; see EmbedSizesMatrixTest.
  defp click_next_step(session) do
    session
    |> execute_script("document.documentElement.style.scrollBehavior = 'auto';")
    |> click(css("[data-testid='next-step']"))
  end

  # The fields validate on blur, so blur the last one before waiting for the
  # submit button to enable.
  defp submit_booking_form(session) do
    session
    |> assert_has(css("[data-testid='booking-form']"))
    |> fill_in(css("input[name='booking[name]']"), with: "Jane Doe")
    |> fill_in(css("input[name='booking[email]']"), with: "jane@example.com")
    |> execute_script("document.activeElement.blur()")
    |> assert_has(css("[data-testid='submit-booking']:not([disabled])"))
    |> click(css("[data-testid='submit-booking']"))
    |> assert_has(css("[data-testid='confirmation-heading']"))
  end

  # The ticket body clips its overflow, so a squeezed entry loses its label
  # silently: the entry's content is wider than the entry itself.
  defp assert_location_entry_unclipped(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const row = document.querySelector("[data-testid='confirmation-location']");
      if (!row) return null;
      return [row.scrollWidth, row.clientWidth];
      """,
      fn value -> send(me, {:location_widths, ref, value}) end
    )

    assert_receive {:location_widths, ^ref, widths}, 5_000
    assert is_list(widths), "#{context}: the confirmation location entry is not in the DOM"
    [scroll_w, client_w] = widths

    assert scroll_w <= client_w + @overflow_tolerance,
           "#{context}: the location entry's content is #{scroll_w}px wide in a " <>
             "#{client_w}px entry, so the ticket body clips it. The arranged-note " <>
             "row needs a flex basis that wraps it onto its own line."

    session
  end
end
