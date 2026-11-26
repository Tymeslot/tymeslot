defmodule TymeslotWeb.E2E.EmbedPreviewTest do
  @moduledoc """
  The Live Preview on `/dashboard/embed`: the `EmbedPreview` hook rebuilds
  the preview from the options the organiser picks.

  The server only renders the choices onto the preview container's `data-*`
  attributes (covered by the embed settings LiveView tests); the iframe, the
  popup button and the modal are drawn by the hook in the browser, so only a
  browser can show the preview following a change. Both modes are the
  organiser's own preview, so the framed page must show the owner-preview
  notice: the signed token that makes a booking there a simulation.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes

  @moduletag :e2e
  @moduletag :dashboard

  @container "#live-preview-container"

  feature "the live preview follows the layout, language, width and mode picked",
          %{session: session} do
    {session, user} = log_in_via_browser(session)
    make_bookable(user)

    session =
      session
      |> resize_window(1280, 900)
      |> visit("/dashboard/embed")
      |> wait_for_live()
      |> show_tab("preview")

    # The defaults: an inline frame in the column layout, in the browser's
    # language.
    session
    |> focus_frame(css("#{@container} iframe"))
    |> assert_has(css("html[lang='en'][data-embed-layout='column']"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> assert_has(css("[data-testid='preview-notice']"))
    |> focus_default_frame()

    # Picked on the options tab, the choices rebuild the frame.
    session =
      session
      |> show_tab("options")
      |> choose("embed-layout", "Default")
      |> choose("embed-language", "Deutsch")
      |> fill_in(css("#embed-max-width"), with: "600")
      |> send_keys([:tab])
      |> assert_has(css("#{@container}[data-max-width='600'][data-locale='de']", visible: :any))
      |> show_tab("preview")

    assert evaluate_script(session, """
           return Math.round(document.querySelector('#{@container} iframe')
             .getBoundingClientRect().width);
           """) == 600

    session
    |> focus_frame(css("#{@container} iframe"))
    |> assert_has(css("html[lang='de'][data-embed-layout='default']"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> focus_default_frame()

    # Popup mode: the preview becomes the snippet's button, labelled in the
    # embed's language, and it opens the booking page in the loader's modal,
    # still as the organiser's simulated preview.
    session
    |> show_tab("options")
    |> click(css(".embed-option-card[phx-value-type='popup']"))
    |> assert_has(css("#{@container}[data-embed-type='popup']", visible: :any))
    |> show_tab("preview")
    |> refute_has(css("#{@container} iframe"))
    |> click(css("#{@container} button", text: "Termin buchen"))
    |> assert_has(css("#tymeslot-modal[role='dialog']"))
    |> focus_frame(css("#tymeslot-modal iframe"))
    |> assert_has(css("html[lang='de']"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> assert_has(css("[data-testid='preview-notice']"))
    |> focus_default_frame()
    |> click(css("#tymeslot-modal [data-tymeslot-close]"))
    |> assert_has(css("#tymeslot-modal", count: 0, visible: :any))
  end

  defp show_tab(session, tab) do
    session
    |> click(css("#embed-settings-tabs-tab-#{tab}"))
    |> assert_has(css("#embed-settings-tabs-panel-#{tab}"))
  end

  # Opens one of the dashboard's `<.select>`s and clicks the option labelled
  # `label`.
  defp choose(session, id, label) do
    session
    |> click(css("##{id}-trigger"))
    |> click(css("##{id}-panel [role='option']", text: label))
    |> assert_has(css("##{id}-trigger[aria-expanded='false']"))
  end

  defp make_bookable(user) do
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Embed Preview Check",
        duration_minutes: 30,
        is_active: true
      })
  end
end
