defmodule TymeslotWeb.OnboardingLive.ReadyStep do
  @moduledoc """
  Final step of the onboarding flow: the page is live, and the host keeps
  the link.

  The link itself leads the column, in full and selectable, with a one-tap
  Copy beside it. The stage shows the host's real booking page
  (`StageFrame`, iframe mode), so "Try booking yourself" leads there. The
  question column then asks for one keep action, any of which completes
  onboarding (`NavigationHandlers.handle_keep_link/2`):

    * **Copy.** The link's own Copy button.
    * **First person.** An optional name and "Send them your link". The
      message is built here, server-side, and handed to the `ShareLink`
      hook, which opens the device's share sheet where there is one and the
      mail client otherwise. On a desktop, "Copy message" copies it instead.
    * **For later.** Email the link to yourself, copy an email signature
      line, or (from `lg`) scan a QR code to open the page on a phone, which
      counts once the phone opens it.

  Each confirmation shows where its button is: a keep button's own label
  gives way to it (`kept_swap/1`, which reserves the wider of the two, so
  nothing moves), and the first-person card keeps a line for its own. The
  layout's one polite live region announces it as well.

  "Go to dashboard" stays locked (`aria-disabled`, still focusable) until a
  keep action, and then only navigates. A page that is not live (no
  bookable calendar any more) cannot be kept, so its actions grey out and
  finishing stays open.

  Every copy happens client-side in `CopyOnClick`, so the copy buttons also
  carry `phx-click="keep_link"` to tell the server.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents,
    only: [action_button: 1, glass_morphism_card: 1, icon: 1, info_box: 1, input: 1]

  alias Phoenix.LiveView.JS

  @name_max_length 60

  @doc "The longest first-person name the message takes."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length

  @doc """
  The message sent to the first person, with their name when one is given.
  """
  @spec share_text(String.t() | nil, String.t()) :: String.t()
  def share_text(name, url) do
    case String.trim(name || "") do
      "" ->
        dgettext("onboarding_wizard", "You can pick a time with me here: %{url}", url: url)

      name ->
        dgettext("onboarding_wizard", "Hi %{name}, you can pick a time with me here: %{url}",
          name: name,
          url: url
        )
    end
  end

  @doc """
  What the first-person card confirms after a keep action, by method.
  """
  @spec kept_label(String.t()) :: String.t()
  def kept_label(method) when method in ["first_person", "share_sheet"],
    do: dgettext("onboarding_wizard", "Sent")

  # The mail client was opened with the message: nothing is sent until the
  # host sends it there.
  def kept_label("mail_app"), do: dgettext("onboarding_wizard", "Opened in your email app")
  def kept_label("message_copy"), do: dgettext("onboarding_wizard", "Message copied")

  def kept_label("email_me"), do: dgettext("onboarding_wizard", "Emailed to you")
  def kept_label("copy"), do: dgettext("onboarding_wizard", "Copied")
  def kept_label("signature"), do: dgettext("onboarding_wizard", "Signature copied")
  def kept_label("phone"), do: dgettext("onboarding_wizard", "Opened on your phone")
  def kept_label("restored"), do: dgettext("onboarding_wizard", "Your link is saved")

  @doc """
  Renders the share step.

  ## Attributes

  * `booking_url` - The user's full booking URL string
  * `page_live` - Whether the booking page accepts visitors. When it does not
    (no bookable calendar), every keep action is greyed out and a warning
    explains why, with a way back to the calendar step. `nil` on the
    disconnected render, where it is not known yet: the actions stay greyed
    out without a warning, so a live page never first renders as offline.
  * `kept_method` - The latest keep action's confirmation (a key of
    `kept_label/1`), or `nil` before the first
  * `first_person_name` - The name typed for the first person
  * `email` - The host's own address, for "Sent to"
  * `handoff_qr` - The QR code's data URI once shown, else `nil`
  * `handoff_url` - The link the QR code carries, once shown
  * `handoff_ready` - Whether the QR code can be shown yet (connected only)
  * `finish_locked` - Whether "Go to dashboard" still waits for a keep
  """
  attr :booking_url, :string, required: true
  attr :page_live, :boolean, required: true
  attr :kept_method, :string, default: nil
  attr :first_person_name, :string, default: ""
  attr :email, :string, default: nil
  attr :handoff_qr, :string, default: nil
  attr :handoff_url, :string, default: nil
  attr :handoff_ready, :boolean, default: false
  attr :finish_locked, :boolean, default: true

  @spec ready_step(map()) :: Phoenix.LiveView.Rendered.t()
  def ready_step(assigns) do
    assigns =
      assign(assigns,
        share_text: share_text(assigns.first_person_name, assigns.booking_url),
        signature: signature(assigns.booking_url),
        link_parts: link_parts(assigns.booking_url),
        actions_off: assigns.page_live != true
      )

    ~H"""
    <div class="space-y-6">
      <div id="onboarding-link-hero" class="onboarding-link-hero">
        <%!-- It breaks before the name first, then anywhere, but is never
             cut off. --%>
        <p id="onboarding-booking-link" class="onboarding-link-text">
          {elem(@link_parts, 0)}<wbr />{elem(@link_parts, 1)}
        </p>
        <.action_button
          id="onboarding-keep-copy"
          variant={:secondary}
          size={:sm}
          icon={if @kept_method == "copy", do: "hero-check-circle-mini", else: "hero-link"}
          class="shrink-0"
          disabled={@actions_off}
          phx-hook="CopyOnClick"
          phx-click="keep_link"
          phx-value-method="copy"
          data-copy-text={@booking_url}
          data-copy-feedback={dgettext("onboarding_wizard", "Copied")}
        >
          <.kept_swap
            kept={@kept_method == "copy"}
            label={dgettext("onboarding_wizard", "Copy link")}
            done={kept_label("copy")}
          />
        </.action_button>
      </div>

      <.info_box :if={@page_live == false} variant={:warning}>
        <div id="onboarding-page-offline-warning" class="space-y-3">
          <p class="font-semibold">
            {dgettext("onboarding_wizard", "Your booking page isn't live yet")}
          </p>
          <p>
            {dgettext(
              "onboarding_wizard",
              "No working calendar is connected, so anyone who opens your link is told the page isn't available. Connect one to go live."
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

      <p :if={@page_live} class="onboarding-try-booking text-token-sm text-tymeslot-600">
        <%!-- On a desktop the page is right beside the column; on a phone
             the stage card is a glimpse, so the expanded page is where to
             try it. --%>
        <button
          id="onboarding-try-booking"
          type="button"
          class="onboarding-text-link hidden lg:inline"
          phx-click={JS.push("try_booking") |> JS.focus(to: "#onboarding-stage-iframe")}
          aria-describedby="onboarding-try-booking-note"
        >
          {dgettext("onboarding_wizard", "Try booking yourself")}
        </button>
        <button
          id="onboarding-try-booking-phone"
          type="button"
          class="onboarding-text-link lg:hidden"
          phx-click="try_booking"
          phx-value-expand="true"
          aria-describedby="onboarding-try-booking-note"
        >
          {dgettext("onboarding_wizard", "Try booking yourself")}
        </button>
        <span id="onboarding-try-booking-note">
          {dgettext("onboarding_wizard", "Test bookings don't create meetings or send emails.")}
        </span>
      </p>

      <.glass_morphism_card id="onboarding-first-person" class="onboarding-keep-card p-5 space-y-4">
        <form
          id="onboarding-first-person-form"
          phx-change="first_person_name"
          phx-submit="first_person_name"
        >
          <.input
            type="text"
            id="onboarding-first-person-name"
            name="name"
            value={@first_person_name}
            label={dgettext("onboarding_wizard", "Who should book you first?")}
            placeholder={dgettext("onboarding_wizard", "Their name (optional)")}
            maxlength={name_max_length()}
            autocomplete="off"
            phx-debounce="150"
          />
        </form>

        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <.action_button
            id="onboarding-send-link"
            icon="hero-paper-airplane"
            class="w-full sm:w-auto"
            disabled={@actions_off}
            phx-hook="ShareLink"
            data-share-text={@share_text}
            data-share-subject={dgettext("onboarding_wizard", "Book a time with me")}
          >
            {dgettext("onboarding_wizard", "Send them your link")}
          </.action_button>
          <button
            :if={!@actions_off}
            id="onboarding-copy-message"
            type="button"
            class="onboarding-text-link hidden lg:inline text-token-sm"
            phx-hook="CopyOnClick"
            phx-click="keep_link"
            phx-value-method="first_person"
            phx-value-via="copy"
            data-copy-text={@share_text}
            data-copy-feedback={dgettext("onboarding_wizard", "Message copied")}
          >
            {dgettext("onboarding_wizard", "Copy message")}
          </button>

          <%!-- One line reserved whether or not there is anything to
               confirm, so the confirmation appearing never moves the card. --%>
          <p class="onboarding-kept-line" data-role="first-person-kept">
            <span
              :if={card_confirmation?(@kept_method)}
              id="onboarding-kept"
              class="inline-flex items-center gap-2"
            >
              <.icon name="hero-check-circle-mini" class="w-5 h-5 shrink-0" />
              {kept_label(@kept_method)}
            </span>
          </p>
        </div>
      </.glass_morphism_card>

      <div class="space-y-3">
        <p class="text-token-sm font-medium text-tymeslot-600">
          {dgettext("onboarding_wizard", "Or keep it for later")}
        </p>
        <div class="onboarding-keep-actions">
          <.action_button
            id="onboarding-keep-email"
            variant={:secondary}
            icon={if @kept_method == "email_me", do: "hero-check-circle-mini", else: "hero-envelope"}
            disabled={@actions_off}
            phx-click="keep_link"
            phx-value-method="email_me"
          >
            <.kept_swap
              kept={@kept_method == "email_me"}
              label={dgettext("onboarding_wizard", "Email me my link")}
              done={email_sent_label(@email)}
            />
          </.action_button>
          <.action_button
            id="onboarding-keep-signature"
            variant={:secondary}
            icon={
              if @kept_method == "signature", do: "hero-check-circle-mini", else: "hero-pencil-square"
            }
            disabled={@actions_off}
            phx-hook="CopyOnClick"
            phx-click="keep_link"
            phx-value-method="signature"
            data-copy-text={@signature}
            data-copy-feedback={dgettext("onboarding_wizard", "Signature copied")}
          >
            <.kept_swap
              kept={@kept_method == "signature"}
              label={dgettext("onboarding_wizard", "Add to email signature")}
              done={kept_label("signature")}
            />
          </.action_button>
          <%!-- A phone is already the phone: the QR code is for a desktop. --%>
          <.action_button
            id="onboarding-keep-phone"
            variant={:secondary}
            icon={if @kept_method == "phone", do: "hero-check-circle-mini", else: "hero-qr-code"}
            class="onboarding-keep-phone"
            disabled={@actions_off or not @handoff_ready}
            phx-click="show_handoff_qr"
            aria-expanded={to_string(not is_nil(@handoff_qr))}
            aria-controls="onboarding-handoff-qr"
          >
            <.kept_swap
              kept={@kept_method == "phone"}
              label={dgettext("onboarding_wizard", "Open on your phone")}
              done={kept_label("phone")}
            />
          </.action_button>
        </div>

        <.info_box :if={@kept_method == "signature"} variant={:info} class="mb-0 p-4">
          <ul id="onboarding-signature-help" class="space-y-1 text-token-sm">
            <li>
              {dgettext(
                "onboarding_wizard",
                "Gmail: Settings, See all settings, then Signature."
              )}
            </li>
            <li>
              {dgettext("onboarding_wizard", "Outlook: Settings, Mail, then Compose and reply.")}
            </li>
            <li>
              {dgettext("onboarding_wizard", "Apple Mail: Settings, then Signatures.")}
            </li>
          </ul>
        </.info_box>

        <div
          :if={@handoff_qr}
          id="onboarding-handoff-qr"
          class="onboarding-handoff-qr"
          data-handoff-url={@handoff_url}
        >
          <img
            src={@handoff_qr}
            alt={dgettext("onboarding_wizard", "QR code for your booking page")}
            width="160"
            height="160"
          />
          <p class="text-token-sm text-tymeslot-600">
            {dgettext("onboarding_wizard", "Scan with your phone camera.")}
          </p>
        </div>
      </div>

      <p
        :if={@page_live}
        id="onboarding-what-next"
        class="flex items-start gap-2 text-token-sm text-tymeslot-600"
      >
        <.icon name="hero-bell-alert-mini" class="w-5 h-5 shrink-0 text-turquoise-600" />
        <span>
          {dgettext(
            "onboarding_wizard",
            "When someone books, you'll get an email and the meeting appears in your dashboard."
          )}
        </span>
      </p>

      <div class="onboarding-finish">
        <.action_button
          id="onboarding-finish"
          variant={if @finish_locked, do: :secondary, else: :primary}
          size={:lg}
          class="w-full"
          aria-disabled={@finish_locked && "true"}
          aria-describedby={@finish_locked && "onboarding-finish-helper"}
          phx-click={if @finish_locked, do: "finish_locked", else: "next_step"}
        >
          {dgettext("onboarding_wizard", "Go to dashboard")}
          <.icon name="hero-arrow-right-mini" class="w-5 h-5 shrink-0" />
        </.action_button>
        <p
          :if={@finish_locked}
          id="onboarding-finish-helper"
          class="mt-2 text-center text-token-sm text-tymeslot-500"
        >
          {dgettext("onboarding_wizard", "Send or keep your link first")}
        </p>
      </div>
    </div>
    """
  end

  # A keep button's label, which gives way to its confirmation once that
  # button has kept the link. Both are laid in the same grid cell and the
  # hidden one keeps its room, so the button never changes size.
  attr :kept, :boolean, required: true
  attr :label, :string, required: true
  attr :done, :string, required: true

  defp kept_swap(assigns) do
    ~H"""
    <span class="onboarding-kept-swap" data-kept={@kept}>
      <span class="onboarding-kept-swap-label" aria-hidden={@kept && "true"}>{@label}</span>
      <span class="onboarding-kept-swap-done" aria-hidden={!@kept && "true"}>{@done}</span>
    </span>
    """
  end

  # The confirmations the first-person card shows on its own line: its own
  # two ways to send, and the link kept on an earlier connection.
  defp card_confirmation?(method),
    do: method in ~w(first_person share_sheet mail_app message_copy restored)

  defp email_sent_label(email) when is_binary(email),
    do: dgettext("onboarding_wizard", "Sent to %{email}", email: email)

  defp email_sent_label(_email), do: kept_label("email_me")

  # The link as the address and the name, split before the last `/`.
  # Shown without the scheme, as the stage's address bar shows it, so the
  # browser never breaks the line after "https://". Copy keeps the full URL.
  defp link_parts(url) do
    case url |> String.replace(~r{^https?://}, "") |> String.split(~r{(?=/[^/]*$)}, parts: 2) do
      [address, name] -> {address, name}
      [whole] -> {whole, ""}
    end
  end

  defp signature(booking_url),
    do: dgettext("onboarding_wizard", "Book a time with me: %{url}", url: booking_url)
end
