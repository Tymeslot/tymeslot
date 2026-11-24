defmodule TymeslotWeb.E2E.TooltipTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Fluffy.Playwright.Keyboard

  @moduletag :e2e
  @moduletag :profiles

  @tip "#language-automatic-tip"

  test "a tooltip shows on hover and on keyboard focus, and Escape dismisses it", %{
    session: session
  } do
    {session, _user} = log_in_via_browser(session)
    session = session |> visit("/dashboard/account") |> wait_for_live()

    # Hover shows it, and it is a real popover carrying the text.
    trigger = by_css("button[aria-describedby='language-automatic-tip']")

    session
    |> hover(trigger)
    |> assert_has(
      filter(by_css("#{@tip}:popover-open"), has_text: "Follow your browser's language setting")
    )
    |> assert_placed_on_screen()

    # Tabbing to the control shows it; Escape closes it while focus stays.
    session
    |> hover(by_css("h1"))
    |> refute_has(by_css("#{@tip}:popover-open"))
    |> tab_to("language-automatic-tip")
    |> assert_has(by_css("#{@tip}:popover-open"))
    |> Keyboard.press("Escape")
    |> refute_has(by_css("#{@tip}:popover-open"))
  end

  # The bubble was placed by the script, inside the viewport and not at the
  # popover's default centre of the screen.
  defp assert_placed_on_screen(session) do
    rect =
      evaluate_script(session, """
      const b = document.querySelector("#{@tip}").getBoundingClientRect();
      return {top: b.top, left: b.left, right: b.right, vw: innerWidth,
              style: document.querySelector("#{@tip}").style.top};
      """)

    assert rect["style"] != ""
    assert rect["top"] >= 0
    assert rect["left"] >= 0
    assert rect["right"] <= rect["vw"]
    session
  end

  # Presses Tab until the focused control is the one describing `tip_id`.
  defp tab_to(session, tip_id, tries \\ 40) do
    {:ok, session} = focus_prior_step(session)

    Enum.reduce_while(1..tries, session, fn _try, session ->
      session = Keyboard.press(session, "Tab")

      if focused_control_describes?(session, tip_id),
        do: {:halt, session},
        else: {:cont, session}
    end)
  end

  defp focus_prior_step(session) do
    evaluate_script(session, "document.body.focus && document.body.focus()")
    {:ok, session}
  end

  defp focused_control_describes?(session, tip_id) do
    evaluate_script(session, "return document.activeElement.getAttribute('aria-describedby')") ==
      tip_id
  end
end
