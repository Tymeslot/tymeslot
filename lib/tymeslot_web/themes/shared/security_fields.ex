defmodule TymeslotWeb.Themes.Shared.SecurityFields do
  @moduledoc """
  Shared security field components for booking forms.

  Provides honeypot and reCAPTCHA fields to prevent spam and bot submissions.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers

  @doc """
  Renders a honeypot field to catch automated bot submissions.

  The field is hidden from real users using absolute positioning (not sr-only)
  and aria-hidden to prevent screen reader announcement. The field uses:
  - `tabindex="-1"` to prevent keyboard navigation
  - `autocomplete="off"` to prevent browser autofill

  Bots that fill this field will be silently rejected with a fake success message.

  ## Parameters

    * `id_prefix` - Prefix for the field ID (e.g., "booking")
    * `param_root` - Root parameter name (e.g., "booking" for booking[website])
  """
  attr :id_prefix, :string, required: true
  attr :param_root, :string, required: true

  @spec honeypot_field(map()) :: Phoenix.LiveView.Rendered.t()
  def honeypot_field(assigns) do
    ~H"""
    <%!-- Honeypot field (hidden from real users, visible to bots) --%>
    <div class="honeypot-field" aria-hidden="true">
      <label for={"#{@id_prefix}-website"}>Website</label>
      <input
        id={"#{@id_prefix}-website"}
        type="text"
        name={"#{@param_root}[website]"}
        tabindex="-1"
        autocomplete="off"
        value=""
      />
    </div>
    """
  end

  @doc """
  Renders reCAPTCHA v3 fields and privacy notice if reCAPTCHA is active.

  Includes:
  - Hidden input field for the reCAPTCHA token
  - Privacy notice with links to Google's Privacy Policy and Terms of Service

  Only renders if reCAPTCHA is enabled and properly configured with keys.

  ## Parameters

    * `id_prefix` - Prefix for the field ID (e.g., "booking")
    * `param_root` - Root parameter name (e.g., "booking")
  """
  attr :id_prefix, :string, required: true
  attr :param_root, :string, required: true

  @spec recaptcha_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def recaptcha_fields(assigns) do
    ~H"""
    <%= if RecaptchaHelpers.booking_active?() do %>
      <input
        type="hidden"
        name={"#{@param_root}[g-recaptcha-response]"}
        id={"#{@id_prefix}-g-recaptcha-response"}
        value=""
      />
      <div class="recaptcha-notice text-xs text-tymeslot-500 text-center">
        {Phoenix.HTML.raw(recaptcha_notice())}
      </div>
    <% end %>
    """
  end

  defp recaptcha_notice do
    link_class = "text-turquoise-600 underline hover:text-turquoise-700"

    privacy_link =
      ~s(<a href="https://policies.google.com/privacy" target="_blank" rel="noopener noreferrer" class="#{link_class}">) <>
        gettext("Privacy Policy") <> "</a>"

    terms_link =
      ~s(<a href="https://policies.google.com/terms" target="_blank" rel="noopener noreferrer" class="#{link_class}">) <>
        gettext("Terms of Service") <> "</a>"

    gettext(
      "This site is protected by reCAPTCHA and the Google %{privacy_link} and %{terms_link} apply.",
      privacy_link: privacy_link,
      terms_link: terms_link
    )
  end

  @doc """
  Returns map of reCAPTCHA data attributes for form element if active.

  Use this on the form tag to enable reCAPTCHA v3 via the RecaptchaV3 hook.

  ## Example

      <.form
        for={@form}
        phx-submit="submit"
        {recaptcha_form_attrs("booking_form", "booking")}
      >
  """
  @spec recaptcha_form_attrs(String.t(), String.t()) :: map()
  def recaptcha_form_attrs(action, param_root) do
    if RecaptchaHelpers.booking_active?() do
      %{
        :"data-site-key" => RecaptchaHelpers.site_key(),
        :"data-recaptcha-action" => action,
        :"data-recaptcha-event" => "submit",
        :"data-recaptcha-param-root" => param_root,
        :"data-recaptcha-require-token" => "true",
        :"phx-hook" => "RecaptchaV3"
      }
    else
      %{}
    end
  end
end
