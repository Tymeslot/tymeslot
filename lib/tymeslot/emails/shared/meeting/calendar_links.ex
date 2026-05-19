defmodule Tymeslot.Emails.Shared.Meeting.CalendarLinks do
  @moduledoc """
  Add-to-calendar card for meeting emails — Google, Outlook, and Yahoo buttons
  inside a tinted card.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles, Urls}

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "An add-to-calendar card with Google, Outlook and Yahoo buttons."
  @spec calendar_links_section(%{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:description) => String.t(),
          required(:location) => String.t(),
          optional(atom()) => term()
        }) :: String.t()
  def calendar_links_section(meeting_details) do
    links = Urls.calendar_links(meeting_details)

    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="20px 22px 8px 22px"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          align="left"
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{dgettext("emails", "Add to your calendar")}
        </mj-text>
      </mj-column>
    </mj-section>
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="0 0 #{Styles.card_radius()} #{Styles.card_radius()}"
      padding="0 14px 20px 14px"
    >
      <mj-group>
        #{calendar_button(links.google, "Google")}
        #{calendar_button(links.outlook, "Outlook")}
        #{calendar_button(links.yahoo, "Yahoo")}
      </mj-group>
    </mj-section>
    """
  end

  defp calendar_button(url, label) do
    safe_url = Sanitise.sanitize_url(url)

    """
    <mj-column>
      <mj-button
        href="#{safe_url}"
        background-color="#{Styles.surface()}"
        color="#{Styles.ink_soft()}"
        border="1px solid #{Styles.hairline()}"
        border-radius="#{Styles.radius(:pill)}"
        font-size="13px"
        font-weight="600"
        inner-padding="10px 16px"
      >
        #{label}
      </mj-button>
    </mj-column>
    """
  end
end
