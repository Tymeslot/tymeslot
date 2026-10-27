defmodule TymeslotWeb.OnboardingLive.ReadyStep do
  @moduledoc """
  Final step of the onboarding flow: share the booking link.

  Onboarding publishes the host's page, so this step hands the link off rather
  than signing off. Copying the URL is the primary action, with one-tap email,
  WhatsApp and LinkedIn shares beside it. Every action sends a
  `share_booking_link` event carrying its channel; the copy itself happens
  client-side in the `CopyOnClick` hook, so the `phx-click` is what tells the
  server it happened. "Go to dashboard" in the layout footer stays, but as a
  secondary action.

  A page without a bookable calendar refuses visitors, so in that case the
  actions are greyed out and a warning offers the way back to the calendar
  step; the host can also finish and connect one later from the dashboard.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents,
    only: [action_button: 1, action_link: 1, icon: 1, info_box: 1]

  @share_channels ~w(copy email whatsapp linkedin)

  @doc "The channels a `share_booking_link` event may report."
  @spec share_channels() :: [String.t()]
  def share_channels, do: @share_channels

  @doc """
  Renders the share step.

  ## Attributes

  * `booking_url` - The user's full booking URL string
  * `page_live` - Whether the booking page accepts visitors. When it does not
    (no bookable calendar), every share action is greyed out and a warning
    explains why, with a way back to the calendar step. `nil` on the
    disconnected render, where it is not known yet: the actions stay greyed
    out without a warning, so a live page never first renders as offline.
  """
  attr :booking_url, :string, required: true
  attr :page_live, :boolean, required: true

  @spec ready_step(map()) :: Phoenix.LiveView.Rendered.t()
  def ready_step(assigns) do
    assigns = assign(assigns, :shares, shares(assigns.booking_url))

    ~H"""
    <div class="space-y-6">
      <.info_box :if={@page_live == false} variant={:warning}>
        <div id="onboarding-page-offline-warning" class="space-y-3">
          <p class="font-semibold">
            {dgettext("onboarding_wizard", "Your booking page isn't live yet")}
          </p>
          <p>
            {dgettext(
              "onboarding_wizard",
              "No working calendar is connected, so anyone who opens your link is told the page isn't available. Connect one now, or later from Integrations on your dashboard."
            )}
          </p>
          <.action_button
            id="onboarding-return-to-calendar"
            size={:sm}
            icon="hero-calendar-days"
            phx-click="return_to_calendar_step"
          >
            {dgettext("onboarding_wizard", "Connect a calendar")}
          </.action_button>
        </div>
      </.info_box>

      <%!-- Booking URL display --%>
      <div class={["onboarding-url-display", @page_live == false && "opacity-60"]}>
        <.icon name="hero-link" class="w-5 h-5 text-tymeslot-400 shrink-0" />
        <span class="truncate">{@booking_url}</span>
      </div>

      <.action_button
        id="onboarding-copy-booking-url"
        icon="hero-clipboard-document"
        size={:lg}
        class="w-full"
        disabled={@page_live != true}
        phx-hook="CopyOnClick"
        phx-click="share_booking_link"
        phx-value-channel="copy"
        data-copy-text={@booking_url}
        data-copy-feedback={dgettext("onboarding_wizard", "Booking link copied!")}
      >
        {dgettext("onboarding_wizard", "Copy booking link")}
      </.action_button>

      <div class="space-y-3">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext("onboarding_wizard", "Or send it straight away")}
        </p>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <%= for share <- @shares do %>
            <.action_link
              :if={@page_live}
              id={"onboarding-share-#{share.channel}"}
              variant={:outline}
              icon={share.icon}
              href={share.href}
              target={share.new_tab && "_blank"}
              rel={share.new_tab && "noopener noreferrer"}
              phx-click="share_booking_link"
              phx-value-channel={share.channel}
            >
              {share.label}
            </.action_link>
            <.action_button
              :if={!@page_live}
              id={"onboarding-share-#{share.channel}"}
              variant={:outline}
              icon={share.icon}
              disabled
            >
              {share.label}
            </.action_button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Shared text is percent-encoded with everything but unreserved characters
  # escaped, so spaces become %20 (mail clients show a form-encoded `+`
  # literally).
  defp shares(booking_url) do
    text = share_text(booking_url)

    [
      %{
        channel: "email",
        label: dgettext("onboarding_wizard", "Email"),
        icon: "hero-envelope",
        href: mailto_url(text),
        new_tab: false
      },
      %{
        channel: "whatsapp",
        label: "WhatsApp",
        icon: "hero-chat-bubble-left-right",
        href: "https://wa.me/?text=" <> URI.encode(text, &URI.char_unreserved?/1),
        new_tab: true
      },
      %{
        channel: "linkedin",
        label: "LinkedIn",
        icon: "hero-briefcase",
        href:
          "https://www.linkedin.com/sharing/share-offsite/?url=" <>
            URI.encode(booking_url, &URI.char_unreserved?/1),
        new_tab: true
      }
    ]
  end

  defp share_text(booking_url) do
    dgettext("onboarding_wizard", "You can book a time with me here: %{url}", url: booking_url)
  end

  defp mailto_url(share_text) do
    subject = dgettext("onboarding_wizard", "Book a time with me")

    "mailto:?subject=" <>
      URI.encode(subject, &URI.char_unreserved?/1) <>
      "&body=" <> URI.encode(share_text, &URI.char_unreserved?/1)
  end
end
